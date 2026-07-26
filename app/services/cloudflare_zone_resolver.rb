# Shared: find the connected, verified Cloudflare account whose zone owns a
# domain (apex or subdomain). Used by both the put-behind and cache-purge flows
# so the "which account owns this domain?" logic lives in one place.
module CloudflareZoneResolver
  # scope: the Organization whose connected Cloudflare credentials to search.
  # Returns [credential, zone_hash] or [nil, nil] when no connected account owns it.
  def resolve_cloudflare_zone(scope, domain)
    resolve_cloudflare_zone_in(scope&.credentials&.where(provider: "cloudflare") || [], domain)
  end

  # Same, but over an explicit collection of Cloudflare credentials (e.g. every
  # account an actor can see) — for zone-level ops not tied to a single app.
  def resolve_cloudflare_zone_in(credentials, domain)
    credentials.each do |c|
      zone = c.zones_list.find { |z| domain == z["name"] || domain.end_with?(".#{z['name']}") }
      return [ c, zone ] if zone
    end
    [ nil, nil ]
  end
end
