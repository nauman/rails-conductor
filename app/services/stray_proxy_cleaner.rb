require "shellwords"

# Removes an INERT kamal-proxy container from a host-Caddy box.
#
# When a box finishes migrating off kamal-proxy to host Caddy, the shared
# kamal-proxy container is left behind. Once every app on the box is proxy-less
# it routes nothing and binds nothing — a pure zombie — but it shouldn't linger
# (and raw `docker rm` on prod is deliberately gated). This makes the cleanup a
# first-class, audited Conductor action instead of a hand-run ssh command.
#
# SAFETY — report-first, refuse-unless-provably-inert. It removes the container
# ONLY when:
#   * the server's edge is host-Caddy (never touch a real kamal-proxy box), AND
#   * kamal-proxy routes ZERO services (`kamal-proxy ls` is empty), AND
#   * kamal-proxy publishes no host ports.
# If it still routes or binds anything, REFUSE — removing it would break apps.
# Nothing but the kamal-proxy container is ever touched; never a broad prune.
class StrayProxyCleaner
  CONTAINER = "kamal-proxy".freeze

  Result = Struct.new(:findings, :safe, :removed, :message, keyword_init: true)

  def initialize(server, ssh: nil)
    @server = server
    @ssh = ssh || SshConnection.new(server)
  end

  def inspect_only = evaluate(remove: false)
  def remove!      = evaluate(remove: true)

  private

  def evaluate(remove:)
    present = container_present?
    routes  = present ? routed_services : []
    ports   = present ? published_ports : []
    findings = {
      edge_type: @server.edge_type,
      container_present: present,
      routed_services: routes,
      published_ports: ports
    }

    unless present
      return Result.new(findings: findings, safe: false, removed: false,
                        message: "No kamal-proxy container on #{@server.name} — nothing to remove.")
    end
    unless @server.edge_type == "caddy"
      return Result.new(findings: findings, safe: false, removed: false,
                        message: "#{@server.name} is not a host-Caddy box (edge=#{@server.edge_type.inspect}) — refusing to touch its kamal-proxy.")
    end
    unless routes.empty? && ports.empty?
      return Result.new(findings: findings, safe: false, removed: false,
                        message: "kamal-proxy on #{@server.name} still routes #{routes.size} service(s) / binds #{ports.size} port(s) — removing it would break them. Move those apps to proxy:false first.")
    end

    unless remove
      return Result.new(findings: findings, safe: true, removed: false,
                        message: "kamal-proxy on #{@server.name} is an inert zombie (no routes, no ports). Re-run with confirm:true to remove it.")
    end

    ok = run_ok(%(docker rm -f #{Shellwords.escape(CONTAINER)}))
    Result.new(findings: findings, safe: true, removed: ok,
               message: ok ? "Removed the inert kamal-proxy container from #{@server.name}." :
                             "Removal command failed on #{@server.name} — inspect the box.")
  end

  def container_present?
    capture(%(docker ps -aq --filter name=^#{CONTAINER}$)).to_s.strip.present?
  end

  # `kamal-proxy ls` prints a header row plus one row per routed service. Strip
  # ANSI, drop the header, and anything left is a real route. A stopped proxy
  # fails the exec → no output → treated as routing nothing (also safe).
  def routed_services
    raw = capture(%(docker exec #{CONTAINER} kamal-proxy ls 2>/dev/null)).to_s
    lines = raw.gsub(/\e\[[0-9;]*m/, "").lines.map(&:strip).reject(&:empty?)
    lines.reject { |l| l.match?(/\bService\b/i) && l.match?(/\bTarget\b/i) }
  end

  def published_ports
    capture(%(docker port #{CONTAINER} 2>/dev/null)).to_s.lines.map(&:strip).reject(&:empty?)
  end

  def run_ok(cmd)
    @ssh.execute_with_status(cmd)[:success]
  end

  def capture(cmd)
    res = @ssh.execute_with_status(cmd)
    res[:success] ? (res[:stdout].presence || res[:output]) : nil
  end
end
