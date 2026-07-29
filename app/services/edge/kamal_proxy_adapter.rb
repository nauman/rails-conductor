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

    # kamal-proxy's route key — derived from the host so it's stable + unique.
    def service_for(domain)
      @service.presence || domain.to_s.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-+|-+\z/, "")
    end

    def esc(str) = Shellwords.escape(str.to_s)

    def run!(cmd, what)
      res = @ssh.execute_with_status(cmd)
      return res if res[:success]

      raise Error, "kamal-proxy #{what} failed: #{(res[:stderr].presence || res[:output]).to_s.strip[0, 200]}"
    end
  end
end
