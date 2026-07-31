require "shellwords"

class Edge
  # Publishes a domain on a kamal-proxy box via its CLI — INSTANT cut-over.
  # kamal-proxy routes by Host header, so `kamal-proxy deploy <service> --host
  # <domain> --target <upstream>` registers the route immediately, no redeploy.
  # (The declarative alternative — letting the app's deploy.yml `proxy.host`
  # register the route on its next deploy — is deploy-timed; this primitive flips
  # it now, which is what a transfer's edge phase needs.) The <service> is a
  # stable key derived from the host. Runs over SSH on the target box.
  class KamalProxyAdapter
    class Error < StandardError; end

    PROXY_CONTAINER = "kamal-proxy".freeze

    def initialize(server, ssh: nil, service: nil)
      @server = server
      @ssh = ssh || SshConnection.new(server)
      @service = service
    end

    def publish(domain:, upstream:)
      svc = service_for(domain)
      run!("docker exec #{PROXY_CONTAINER} kamal-proxy deploy #{esc(svc)} " \
           "--host #{esc(domain)} --target #{esc(upstream)} --tls", "publish #{domain}")
      { edge: "kamal_proxy", domain: domain, upstream: upstream, service: svc, applied_by: "kamal-proxy" }
    end

    def unpublish(domain:)
      svc = service_for(domain)
      run!("docker exec #{PROXY_CONTAINER} kamal-proxy remove #{esc(svc)}", "unpublish #{domain}")
      { edge: "kamal_proxy", domain: domain, service: svc, applied_by: "kamal-proxy" }
    end

    private

    # kamal-proxy's route key. Order matters:
    #
    #   1. an explicitly injected service, when the caller knows it;
    #   2. the service that ALREADY serves this host on the live proxy;
    #   3. a key derived from the host.
    #
    # Step 2 is not a nicety. A route created by `kamal deploy` is keyed on the
    # kamal service + role (e.g. "starrrs-web"), not on the host. Publishing the
    # same host under a derived key ("starrrs-com") leaves TWO services claiming
    # one hostname instead of replacing the stale one — which is how you turn a
    # 502 into an intermittent 502.
    def service_for(domain)
      @service.presence || live_service_for(domain) || derived_service(domain)
    end

    def derived_service(domain)
      domain.to_s.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-+|-+\z/, "")
    end

    # Parse `kamal-proxy list` and return the service currently serving `domain`.
    # Best-effort: any failure falls back to the derived key.
    def live_service_for(domain)
      res = @ssh.execute_with_status("docker exec #{PROXY_CONTAINER} kamal-proxy list")
      return nil unless res[:success]

      wanted = domain.to_s.downcase
      res[:output].to_s.each_line do |line|
        service, host = line.split(/\s+/).first(2)
        next if service.blank? || host.blank?
        return service if host.downcase == wanted
      end
      nil
    rescue StandardError
      nil
    end

    def esc(str) = Shellwords.escape(str.to_s)

    def run!(cmd, what)
      res = @ssh.execute_with_status(cmd)
      return res if res[:success]

      raise Error, "kamal-proxy #{what} failed: #{(res[:stderr].presence || res[:output]).to_s.strip[0, 200]}"
    end
  end
end
