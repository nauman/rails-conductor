# Shared: find the connected, verified Cloudflare account whose zone owns a
# domain (apex or subdomain). Used by both the put-behind and cache-purge flows
# so the "which account owns this domain?" logic lives in one place.
module CloudflareZoneResolver
  # scope: the Organization whose connected Cloudflare credentials to search.
  # Returns [credential, zone_hash] or [nil, nil] when no connected account owns it.
  def resolve_cloudflare_zone(scope, domain)
    creds = scope&.credentials&.where(provider: "cloudflare") || []
    creds.each do |c|
      zone = c.zones_list.find { |z| domain == z["name"] || domain.end_with?(".#{z['name']}") }
      return [ c, zone ] if zone
    end
    [ nil, nil ]
  end
end
