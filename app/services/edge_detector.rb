# Detects what fronts a server's web traffic (:80/:443): a host Caddy, a
# kamal-proxy container, some other service, or nothing. Runs over SSH and
# persists the result so the fleet can SHOW the edge (and flag mismatches like a
# kamal-proxy-configured app landing on a Caddy host).
class EdgeDetector
  EDGE_TYPES = %w[caddy kamal_proxy other none unknown].freeze

  # Non-privileged probes (deploy user is in the docker group; no sudo needed).
  DETECT_COMMAND = <<~BASH
    echo "KAMAL_PROXY:$(docker ps --filter 'name=^/kamal-proxy$' --format '{{.Image}}' 2>/dev/null | head -1)"
    echo "KAMAL_PROXY_STATE:$(docker inspect kamal-proxy --format '{{.State.Status}}' 2>/dev/null || echo none)"
    echo "CADDY:$(pgrep -x caddy >/dev/null 2>&1 && echo yes || echo no)"
    echo "CADDY_ADMIN:$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://localhost:2019/config/ 2>/dev/null || echo 000)"
    echo "PORT80:$(ss -tln 2>/dev/null | grep -cE ':80 ')"
    echo "PORT443:$(ss -tln 2>/dev/null | grep -cE ':443 ')"
  BASH

  attr_reader :server, :ssh, :error

  def initialize(server)
    @server = server
    @ssh = SshConnection.new(server)
    @error = nil
  end

  def detect
    return failure("SSH not configured") unless server.ssh_configured?

    output = ssh.execute(DETECT_COMMAND)
    return failure(ssh.error) unless ssh.success?

    self.class.classify(output)
  end

  def detect_and_update!
    result = detect
    return false unless result

    server.update!(edge_type: result[:edge_type], edge_detail: result[:edge_detail], edge_checked_at: Time.current)
    true
  rescue => e
    failure("Update failed: #{e.message}")
    false
  end

  def success?
    @error.nil?
  end

  # Pure classification from the probe output — the testable core.
  def self.classify(output)
    return { edge_type: "unknown", edge_detail: "No probe output" } if output.to_s.strip.empty?

    v = {}
    output.to_s.lines.each do |line|
      key, sep, val = line.strip.partition(":")
      v[key] = val.strip if sep == ":"
    end

    caddy         = v["CADDY"] == "yes" || v["CADDY_ADMIN"] == "200"
    proxy_present = v["KAMAL_PROXY"].to_s != ""
    proxy_running = v["KAMAL_PROXY_STATE"] == "running"
    port_edge     = v["PORT80"].to_i.positive? || v["PORT443"].to_i.positive?

    if caddy
      detail = "Host Caddy"
      detail += " (Admin API)" if v["CADDY_ADMIN"] == "200"
      # Flag the exact trap that bit platepose: a kamal-proxy container sitting
      # inert behind a Caddy edge.
      detail += " — note: an inert kamal-proxy container is also present" if proxy_present && !proxy_running
      { edge_type: "caddy", edge_detail: detail }
    elsif proxy_running
      { edge_type: "kamal_proxy", edge_detail: "kamal-proxy (#{v['KAMAL_PROXY']})" }
    elsif port_edge
      { edge_type: "other", edge_detail: "Unrecognized service on :80/:443" }
    else
      { edge_type: "none", edge_detail: "No web edge detected" }
    end
  end

  private

  def failure(message)
    @error = message
    nil
  end
end
