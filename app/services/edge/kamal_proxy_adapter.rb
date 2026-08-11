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
    # kamal service + role (e.g. "myapp-web"), not on the host. Publishing the
    # same host under a derived key ("myapp-com") leaves TWO services claiming
    # one hostname instead of replacing the stale one — which is how you turn a
    # 502 into an intermittent 502.
    def service_for(domain)
      return @service if @service.present?

      existing, reachable = live_service_for(domain)
      return existing if existing.present?

      # FAIL CLOSED. If the proxy could not be queried we do NOT know whether a
      # route already owns this host, and publishing under a derived key would
      # create a SECOND service claiming it — split, intermittent traffic, which
      # is harder to diagnose than a clean failure.
      unless reachable
        raise Error, "could not read the current routes from kamal-proxy, so the service key for " \
                     "#{domain} is unknown; refusing to publish and risk a duplicate route"
      end

      derived_service(domain) # proxy answered and no route owns this host yet
    end

    def derived_service(domain)
      domain.to_s.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-+|-+\z/, "")
    end

    # Return the service currently serving `domain`, read from the live proxy.
    #
    # The command is `ls`, NOT `list` — same spelling StrayProxyCleaner uses.
    # Its output carries ANSI colour and a "Service / Host / Target ..." header
    # row, both of which must be stripped or the header parses as a route.
    # Best-effort: any failure falls back to the derived key.
    # Returns [service_or_nil, proxy_was_reachable].
    def live_service_for(domain)
      res = @ssh.execute_with_status("docker exec #{PROXY_CONTAINER} kamal-proxy ls 2>/dev/null")
      return [ nil, false ] unless res[:success]

      wanted = domain.to_s.downcase
      res[:output].to_s.gsub(/\e\[[0-9;]*m/, "").lines.each do |line|
        next if line.match?(/\bService\b/i) && line.match?(/\bTarget\b/i) # header

        service, host = line.strip.split(/\s+/).first(2)
        next if service.blank? || host.blank?
        return [ service, true ] if host.downcase == wanted
      end
      [ nil, true ]
    rescue StandardError
      [ nil, false ]
    end

    def esc(str) = Shellwords.escape(str.to_s)

    def run!(cmd, what)
      res = @ssh.execute_with_status(cmd)
      return res if res[:success]

      raise Error, "kamal-proxy #{what} failed: #{(res[:stderr].presence || res[:output]).to_s.strip[0, 200]}"
    end
  end
end
