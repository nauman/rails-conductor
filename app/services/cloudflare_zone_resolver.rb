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
  #
  # "Connected" means active AND verified. Deactivating a credential — the thing
  # an operator does first after a suspected token leak — has to actually stop it
  # driving DNS changes, cache purges, and R2 admin; and a credential that has
  # never passed Verify has an unproven token whose cached zone list may describe
  # an account it can no longer reach. Both are refused here rather than at each
  # call site, because this resolver IS the single "which account owns this?" seam.
  def resolve_cloudflare_zone_in(credentials, domain)
    usable_cloudflare_credentials(credentials).each do |c|
      zone = c.zones_list.find { |z| domain == z["name"] || domain.end_with?(".#{z['name']}") }
      return [ c, zone ] if zone
    end
    [ nil, nil ]
  end

  # Array or relation in, usable credentials out. Kept tolerant of both because
  # callers pass either an association or a plain list.
  def usable_cloudflare_credentials(credentials)
    credentials.select { |c| c.active? && c.verified? }
  end
end
