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
    @ssh = ssh || (app.server && SshConnection.new(app.server))
  end

  def findings
    return [] unless @app.server && @ssh
    return [] if @app.native? # native residue is systemd + release dirs; not modelled yet

    @findings = []
    check_stale_revision_containers
    check_duplicate_legacy_container
    check_foreign_method_containers
    check_edge_routes
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
      %(--format '{{.ID}} {{.Names}} {{.Label "conductor.infra_revision"}} {{.State}}')
    )

    out.lines.map(&:strip).reject(&:empty?).each do |line|
      id, name, revision, state = line.split(/\s+/)
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
    labelled = capture(%(docker ps -q --filter "label=service=#{esc(@app.resource_key)}")).split.size
    legacy   = capture(%(docker ps -q --filter "name=^/#{esc_name(@app.container_name)}$")).split.size
    return unless labelled.positive? && legacy.positive?

    # A labelled container that IS the legacy one is fine — that's a stop-first deploy.
    both = capture(
      %(docker ps -q --filter "label=service=#{esc(@app.resource_key)}" ) +
      %(--filter "name=^/#{esc_name(@app.container_name)}$")
    ).split.size
    return if both.positive?

    @findings << Finding.new(
      kind: "duplicate_container",
      detail: "#{labelled} labelled container(s) AND the legacy #{@app.container_name} are both running",
      remedy: "confirm which one the edge targets, then remove the other"
    )
  end

  # Containers named for a deploy method this app no longer uses. A kamal→docker
  # migration leaves <service>-web-<version> behind; nothing else notices.
  def check_foreign_method_containers
    return if @app.kamal? # these ARE its containers

    @app.kamal_service_candidates.each do |service|
      out = capture(%(docker ps -a --filter "label=service=#{esc(service)}" --format '{{.Names}} {{.State}}'))
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
    rows = out.gsub(/\e\[[0-9;]*m/, "").lines.map(&:strip).reject do |l|
      l.empty? || (l.match?(/\bService\b/i) && l.match?(/\bTarget\b/i))
    end

    owners = rows.filter_map { |l| l.split(/\s+/).first(2) }
                 .select { |(_, host)| host.to_s.casecmp?(@app.domain) }
    return if owners.size <= 1

    @findings << Finding.new(
      kind: "duplicate_edge_route",
      detail: "#{owners.size} kamal-proxy services claim #{@app.domain}: #{owners.map(&:first).join(', ')}",
      remedy: "remove all but the one actually targeting the live container"
    )
  end

  def capture(command)
    res = @ssh.execute_with_status(command)
    res[:success] ? res[:output].to_s : ""
  end

  def esc(str) = Shellwords.escape(str.to_s)
  def esc_name(name) = name.to_s.gsub(/[^a-zA-Z0-9_.-]/, "")
end
