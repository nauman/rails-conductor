require "shellwords"

# Finds infrastructure an app left behind in a PREVIOUS form (ADR 0004).
#
# This is the piece that turns assigned identity into something useful. Because
# containers carry `service=<resource_key>` and `conductor.infra_revision=<n>`,
# "is this artifact current?" stopped being a judgement call and became
# arithmetic: anything whose revision is not the app's current one is, by
# definition, residue.
#
# NOT wired into DeployPreflight, deliberately. Preflight renders on the app
# detail page AND runs on every deploy, and this makes four SSH round-trips — as
# a page-render dependency it hung the page, and on the deploy path an
# unreachable box would stall the deploy on connect timeouts before anything had
# even been attempted. A check that can delay a deploy is worse than the residue
# it looks for.
#
# The right shape is the stored-rollup pattern this codebase already uses for
# server audits (`last_audit_at` / `last_audit_status`): a background job runs
# the detector and persists the findings, and the fast paths read what was
# stored. Until that exists, call this explicitly.
#
# Read-only. It reports; it never removes. Deciding what to delete on a live box
# is an operator's call, and a detector that cleans up is a detector nobody
# trusts to run.
class ResidueDetector
  # kind:   machine-readable category
  # detail: what was found
  # remedy: what a human would do about it
  Finding = Struct.new(:kind, :detail, :remedy, keyword_init: true)

  def initialize(app, ssh: nil)
    @app = app
    @injected_ssh = ssh
    @ssh = ssh || (app.server && SshConnection.new(app.server))
  end

  def findings
    return [] unless @app.server && @ssh
    return [] if @app.native? # native residue is systemd + release dirs; not modelled yet

    @findings = []
    @blind = []
    check_stale_revision_containers
    check_duplicate_legacy_container
    check_foreign_method_containers
    check_edge_routes
    check_previous_servers

    # Say so when we could not look, rather than implying a clean box.
    @blind.each do |why|
      @findings << Finding.new(kind: "unknown", detail: "could not inspect: #{why}",
                               remedy: "fix access to the box, then re-check — this is NOT a clean result")
    end
    @findings
  rescue StandardError => e
    # A detector that fails a deploy because it could not look is worse than no
    # detector. Report the blindness instead.
    [ Finding.new(kind: "unknown", detail: "could not inspect #{@app.server&.name}: #{e.message}",
                  remedy: "check SSH to the box, then re-run") ]
  end

  private

  # Containers wearing this app's service label from an OLDER shape. This is the
  # Starrrs case: an app moved form and the previous form's container kept
  # running, invisible because nothing compared it to anything.
  def check_stale_revision_containers
    out = capture(
      %(docker ps -a --filter "label=service=#{esc(@app.resource_key)}" ) +
      # Pipe-delimited: with whitespace, an EMPTY revision label collapses the
      # field and `state` is read as the revision — a false "stale" finding.
      %(--format '{{.ID}}|{{.Names}}|{{.Label "conductor.infra_revision"}}|{{.State}}')
    )

    return if out.nil?

    out.lines.map(&:strip).reject(&:empty?).each do |line|
      id, name, revision, state = line.split("|")
      next if revision.blank? || revision == @app.infra_revision.to_s

      @findings << Finding.new(
        kind: "stale_revision_container",
        detail: "#{name} (#{id}) is from revision #{revision}; this app is at #{@app.infra_revision} [#{state}]",
        remedy: "verify nothing routes to it, then `docker rm -f #{name}`"
      )
    end
  end

  # Both a release container and the legacy fixed name running at once — the app
  # is being served twice, and which one the edge points at is a coin flip.
  def check_duplicate_legacy_container
    labelled = capture(%(docker ps -q --filter "label=service=#{esc(@app.resource_key)}"))
    legacy   = capture(%(docker ps -q --filter "name=^/#{esc_name(@app.container_name)}$"))
    return if labelled.nil? || legacy.nil?

    # Compare ID SETS, not counts. A boolean "do they overlap?" suppressed the
    # finding whenever the legacy container also carried the stable label, even
    # with a second labelled release running alongside it.
    labelled_ids = labelled.split
    legacy_ids   = legacy.split
    distinct = (labelled_ids | legacy_ids)
    return if distinct.size <= 1

    @findings << Finding.new(
      kind: "duplicate_container",
      detail: "#{distinct.size} containers are serving this app at once: #{distinct.join(', ')}",
      remedy: "confirm which one the edge targets, then remove the other"
    )
  end

  # Containers named for a deploy method this app no longer uses. A kamal→docker
  # migration leaves <service>-web-<version> behind; nothing else notices.
  def check_foreign_method_containers
    return if @app.kamal? # these ARE its containers

    @app.kamal_service_candidates.each do |service|
      out = capture(%(docker ps -a --filter "label=service=#{esc(service)}" --format '{{.Names}}|{{.State}}'))
      next if out.nil?

      out.lines.map(&:strip).reject(&:empty?).each do |line|
        next if line.start_with?(@app.resource_key) # our own, already checked

        @findings << Finding.new(
          kind: "foreign_method_container",
          detail: "#{line} looks like a Kamal-era container, but this app deploys via #{@app.deploy_method}",
          remedy: "if the app is serving correctly, this is residue from the previous form — remove it"
        )
      end
    end
  end

  # More than one proxy route claiming this app's host. This is what publishing
  # under a derived key instead of the existing one produces, and it shows up as
  # intermittent rather than constant failure — the worst kind to diagnose.
  def check_edge_routes
    return if @app.domain.blank?
    return unless @app.server.edge_type == "kamal_proxy"

    out = capture("docker exec kamal-proxy kamal-proxy ls 2>/dev/null")
    return if out.nil?

    rows = out.gsub(/\e\[[0-9;]*m/, "").lines.map(&:strip).reject do |l|
      l.empty? || (l.match?(/\bService\b/i) && l.match?(/\bTarget\b/i))
    end

    # kamal-proxy supports PATH routing, so several services may legitimately
    # serve one host at different prefixes. Only same-host AND same-path is a
    # genuine conflict; ignoring the path column cried wolf on valid setups.
    owners = rows.filter_map { |l| l.split(/\s+/).first(3) }
                 .select { |(_, host, _)| host.to_s.casecmp?(@app.domain) }
                 .group_by { |(_, _, path)| normalize_path(path) }

    owners.each do |path, services|
      next if services.size <= 1

      @findings << Finding.new(
        kind: "duplicate_edge_route",
        detail: "#{services.size} kamal-proxy services claim #{@app.domain}#{path}: #{services.map(&:first).join(', ')}",
        remedy: "remove all but the one actually targeting the live container"
      )
    end
  end

  # A failed command is NOT an empty result. Treating it as one made a broken
  # docker daemon, a permission error, or a missing kamal-proxy look like a clean
  # box — fail-open, which is the worst possible default for a detector whose
  # whole job is noticing things.
  # A third column is only a path when it looks like one — older kamal-proxy
  # builds put the target there instead.
  def normalize_path(value)
    value.to_s.start_with?("/") ? value : ""
  end

  # A box move is the canonical form change, and inspecting only the CURRENT
  # server misses the whole point: the container left running is on the box the
  # app moved AWAY from. The revision history records those moves, so the old
  # boxes are knowable.
  def check_previous_servers
    return if @injected_ssh # a caller-supplied connection points at one box only

    previous_server_ids.each do |server_id|
      server = @app.organization&.servers&.find_by(id: server_id)
      next if server.nil? || !server.ssh_configured?

      on(server) do
        out = capture(
          %(docker ps -a --filter "label=service=#{esc(@app.resource_key)}" --format '{{.Names}}|{{.State}}')
        )
        next if out.nil?

        out.lines.map(&:strip).reject(&:empty?).each do |line|
          name, state = line.split("|")
          @findings << Finding.new(
            kind: "abandoned_server_container",
            detail: "#{name} [#{state}] is still on #{server.name}, which this app moved away from",
            remedy: "confirm the app serves correctly from #{@app.server.name}, then remove it from #{server.name}"
          )
        end
      end
    end
  end

  # Server ids this app has previously been homed on, from its revision history.
  def previous_server_ids
    @app.infra_revisions.filter_map { |r| r.changes_made["server_id"]&.first }
        .compact.map(&:to_i).uniq - [ @app.server_id ]
  end

  # Run a block against a different box, restoring the connection afterwards.
  def on(server)
    original = @ssh
    @ssh = SshConnection.new(server)
    yield
  ensure
    @ssh = original
  end

  def capture(command)
    res = @ssh.execute_with_status(command)
    return res[:output].to_s if res[:success]

    @blind << "#{command[0, 60]}: #{(res[:stderr].presence || res[:output]).to_s.strip[0, 120]}"
    nil
  end

  def esc(str) = Shellwords.escape(str.to_s)
  def esc_name(name) = name.to_s.gsub(/[^a-zA-Z0-9_.-]/, "")
end
