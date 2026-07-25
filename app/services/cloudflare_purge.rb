# Purge an app's Cloudflare edge cache — everything, or specific URLs. Resolves
# the connected account that owns the zone, then POSTs purge_cache. Mirrors
# CloudflareCutover. Use after a deploy when the edge serves stale assets — e.g.
# Cloudflare cached a 404 for a hashed CSS file while the origin was still
# misconfigured (see docs/learnings/static-assets-404-behind-caddy.md).
class CloudflarePurge
  include CloudflareZoneResolver

  Result = Struct.new(:ok, :message, keyword_init: true) do
    def ok? = ok
  end

  def initialize(app, client_for: nil)
    @app = app
    @client_for = client_for || ->(cred) { CloudflareClient.new(cred.api_key) }
  end

  def purge!(files: nil)
    domain = @app.domain
    return failure("#{@app.name} has no domain to purge.") if domain.blank?

    cred, zone = resolve_cloudflare_zone(@app.organization || @app.server&.organization, domain)
    return failure("No connected Cloudflare account owns #{domain}. Connect + Verify the account first.") unless zone

    r = @client_for.call(cred).purge_cache(zone["id"], files: files)
    return failure("Cache purge failed: #{r.error}") unless r.ok?

    scope = Array(files).any? ? "#{Array(files).size} URL(s)" : "everything"
    Result.new(ok: true, message: "Purged Cloudflare cache (#{scope}) for #{domain} via #{cred.name}.")
  end

  private

  def failure(message) = Result.new(ok: false, message: message)
end
