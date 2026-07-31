require "shellwords"

# The discovery-first report for retiring an app FROM a box — the READ-ONLY heart
# of the decommission stage. Mirrors AppTransferPlan (inspect + emit + warnings),
# but where AppTransferPlan reasons about control-plane records, this one SSHes in
# and reports what the box ACTUALLY looks like, because the real state is rarely
# what we assumed: a port held by a native puma instead of docker, a puma AND a
# container both claiming one service, a stale "idle" container still bound.
#
# Mutates NOTHING. The SSH connection is injectable so tests drive canned
# `docker ps` / `ss` / `systemctl` output without touching a real box.
class DecommissionPlan
  class InvalidTarget < StandardError; end

  attr_reader :app, :server

  def initialize(app:, server:, ssh: nil)
    @app = app
    @server = server
    @ssh = ssh
  end

  # Validate the retire is coherent, then expose the (lazy) discovery. Read-only.
  def call
    raise InvalidTarget, "decommission needs a server to retire from" unless server
    raise InvalidTarget, "#{app_label} belongs to another organization" unless app.organization_id == server.organization_id

    self
  end

  def ssh
    @ssh ||= SshConnection.new(server)
  end

  # ---- discovery (each probe memoized; SSH runs on first access) -------------

  # Every app container on this box (running/exited/restarting), matched by the
  # kamal service label AND by name — an adopted app's label may differ from its
  # slug, and a stale container may only match by name.
  def containers
    @containers ||= discover_containers
  end

  # WHAT actually holds the app's port — a docker-proxy (expected) or a native
  # puma/ruby (the classic surprise). The key "different than assumed" probe.
  def port_holder
    @port_holder ||= discover_port_holder
  end

  # Native (non-docker) footprint for this app: systemd --user units and bare
  # puma/ruby processes. Their presence is the docker+native duplication gotcha.
  def native
    @native ||= discover_native
  end

  # The app's dedicated DB container + volume on THIS box (if any).
  def dedicated_db
    @dedicated_db ||= discover_dedicated_db
  end

  # Control-plane records that would be stranded by the retire. No SSH.
  def records
    @records ||= discover_records
  end

  # Labeled findings with a severity, checked against the recurring fleet gotchas
  # every time so the same surprise isn't re-learned box by box.
  def findings
    @findings ||= build_findings
  end

  def to_h
    {
      app: app_label,
      server: server&.name,
      port: app_port,
      containers: containers,
      port_holder: port_holder,
      native: native,
      dedicated_db: dedicated_db,
      records: records,
      findings: findings
    }
  end

  private

  def app_label = app.slug.presence || app.name

  def app_port = app.port || 3000

  # --- probes ----------------------------------------------------------------

  def discover_containers
    filters = app.kamal_service_candidates.map { |s| "label=service=#{s}" }
    filters << "name=#{app.container_name}"
    filters << "name=#{app.slug}"

    seen = {}
    filters.each do |filter|
      out = run(%(docker ps -a --format '{{.Names}}\\t{{.Status}}' --filter #{Shellwords.escape(filter)}))
      parse_container_lines(out).each { |c| seen[c[:name]] ||= c }
    end
    seen.values
  end

  def parse_container_lines(out)
    out.to_s.each_line.filter_map do |line|
      name, status = line.chomp.split("\t", 2)
      next if name.blank?

      { name: name, status: status.to_s, state: container_state(status) }
    end
  end

  def container_state(status)
    case status.to_s
    when /\ARestarting/ then "restarting"
    when /\AExited/     then "exited"
    when /\ACreated/    then "created"
    when /\AUp/         then "running"
    else "unknown"
    end
  end

  def discover_port_holder
    out = run(%(ss -tlnp 'sport = :#{app_port}'))
    process = out.to_s[/users:\(\("([^"]+)"/, 1]
    {
      port: app_port,
      process: process,
      kind: port_holder_kind(process),
      raw: out.to_s.strip.presence
    }
  end

  def port_holder_kind(process)
    return "none" if process.blank?
    return "docker" if process.include?("docker")
    return "native" if process.match?(/puma|ruby|bundle|rails|unicorn|node/)

    "unknown"
  end

  def discover_native
    entries = []
    app.kamal_service_candidates.each do |svc|
      units = run(%(systemctl --user list-units '*#{svc}*' --no-legend 2>/dev/null))
      units.to_s.each_line do |line|
        unit = line.split.first
        entries << { kind: "systemd", detail: unit } if unit.present?
      end

      procs = run(%(pgrep -af 'puma.*#{svc}' 2>/dev/null))
      procs.to_s.each_line do |line|
        entries << { kind: "process", detail: line.chomp } if line.strip.present?
      end
    end
    entries.uniq { |e| [ e[:kind], e[:detail] ] }
  end

  def discover_dedicated_db
    return { present: false } unless app.dedicated_db?

    # Both eras' names (ADR 0004 alias period): a DB container created before
    # stable naming is still <slug>-db, and missing it means reporting "nothing
    # to decommission" while the data container keeps running.
    container = app.dedicated_db_container_candidates
                   .filter_map { |name| run(%(docker ps -a --format '{{.Names}}\\t{{.Status}}' --filter name=#{Shellwords.escape(name)})).presence }
                   .join("\\n")
    row = parse_container_lines(container).first
    volume = run(%(docker volume ls --format '{{.Name}}' --filter name=#{Shellwords.escape(app.dedicated_db_volume)}))

    {
      present: row.present? || volume.to_s.strip.present?,
      container_name: app.dedicated_db_container_name,
      container_state: row && row[:state],
      volume: app.dedicated_db_volume,
      volume_present: volume.to_s.lines.map(&:strip).include?(app.dedicated_db_volume)
    }
  end

  def discover_records
    dbs = app.databases.joins(:database_cluster)
             .where(database_clusters: { server_id: server&.id })
    {
      is_app_home: app.server_id == server&.id,
      app_home_server: app.server&.name,
      databases: dbs.map { |db| db_record_summary(db) }
    }
  end

  def db_record_summary(db)
    cluster = db.database_cluster
    dedicated = app.dedicated_db_container_candidates.include?(cluster.container_name)
    { id: db.id, name: db.name, cluster: cluster.container_name, shared_cluster: !dedicated }
  end

  # --- findings (checked against the recurring gotchas every time) -----------

  def build_findings
    findings = []
    findings.concat(home_findings)
    findings.concat(duplication_findings)
    findings.concat(container_findings)
    findings.concat(shared_db_findings)
    findings
  end

  # (c) the app's home still points here — retiring would orphan the live app.
  def home_findings
    return [] unless records[:is_app_home]

    [ finding("retire_before_move",
              "#{app_label}'s home server is still #{server&.name} — retiring it here would orphan the live " \
              "app. Move it (conductor_app action=transfer) before retiring.") ]
  end

  # (a) native + docker both present for the same service.
  def duplication_findings
    findings = []
    docker_present = containers.any?
    native_present = native.any?

    if docker_present && native_present
      findings << finding("docker_native_duplication",
                          "puma/native AND a docker container both claim #{app_label} on #{server&.name} — " \
                          "remove BOTH or the port stays bound after `docker rm`.")
    end

    if port_holder[:kind] == "native"
      findings << finding("native_vs_docker_port",
                          "the app's port #{app_port} is held by a NATIVE process (#{port_holder[:process]}), " \
                          "not docker-proxy — `docker rm` alone will not free it.")
    end
    findings
  end

  # (b) exited/idle container still present, and (d) a running container that is
  # actually serving — don't blindly remove.
  def container_findings
    findings = []
    containers.each do |c|
      case c[:state]
      when "exited", "created"
        findings << finding("stale_idle_container",
                            "container #{c[:name]} is #{c[:status]} but still present — a stale/idle container " \
                            "left on the box.")
      when "running"
        findings << finding("stale_idle_container",
                            "container #{c[:name]} is #{c[:status]} — still running/serving on #{server&.name}; " \
                            "confirm it is drained before removing.", severity: "info")
      end
    end
    findings
  end

  # Shared-cluster DB copies are never auto-dropped — flag for a human.
  def shared_db_findings
    records[:databases].select { |db| db[:shared_cluster] }.map do |db|
      finding("shared_cluster_db",
              "database record '#{db[:name]}' lives on the SHARED cluster #{db[:cluster]} — it will NOT be " \
              "dropped automatically; hand shared-cluster cleanup to a human.")
    end
  end

  # A finding carries the recurring-gotcha code + its default severity so the
  # runner can fold the matching runbook note in on completion.
  def finding(code, message, severity: nil)
    gotcha = DecommissionGotchas.find(code)
    { code: code, severity: severity || gotcha&.fetch(:severity) || "warning", message: message }
  end

  # Run a read-probe, tolerating an unreachable/unconfigured box: discovery must
  # degrade to "found nothing" rather than raise, so the report is always returned.
  def run(command)
    result = ssh.execute_with_status(command)
    return "" unless result.is_a?(Hash)

    result[:success] ? result[:stdout].to_s : ""
  rescue StandardError
    ""
  end
end
