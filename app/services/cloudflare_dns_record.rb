# Create or update a Cloudflare DNS record (A/CNAME) for a domain in an account
# Conductor is connected to. Idempotent (upsert). Resolves the owning zone from
# the given Cloudflare credentials, then delegates to CloudflareClient. Zero
# vault — Conductor already holds the account token.
class CloudflareDnsRecord
  include CloudflareZoneResolver

  Result = Struct.new(:ok, :message, :record, keyword_init: true) do
    def ok? = ok
  end

  # credentials: a collection of Cloudflare Credential records the actor can use.
  def initialize(credentials, client_for: nil)
    @credentials = credentials
    @client_for = client_for || ->(cred) { CloudflareClient.new(cred.api_key) }
  end

  # Record types Conductor will write. TXT matters for domain verification and
  # email — DKIM, SPF, SES/Google identity tokens — which previously had to be
  # done by hand in the Cloudflare dashboard.
  SUPPORTED_TYPES = %w[A AAAA CNAME TXT].freeze

  # Only address-shaped records can sit behind Cloudflare's proxy. Asking to
  # proxy a TXT record is an API error, so refuse it here with a reason rather
  # than forwarding a request that cannot succeed.
  PROXYABLE_TYPES = %w[A AAAA CNAME].freeze

  def set!(domain:, content:, type: "A", proxied: false)
    return failure("A domain (record name) is required.") if domain.blank?
    return failure("A content value is required (an IP for A, a hostname for CNAME, the value for TXT).") if content.blank?

    type = type.to_s.upcase
    unless SUPPORTED_TYPES.include?(type)
      return failure("Unsupported record type #{type}. Supported: #{SUPPORTED_TYPES.join(', ')}.")
    end

    if proxied && !PROXYABLE_TYPES.include?(type)
      return failure("#{type} records cannot be proxied through Cloudflare — set proxied: false.")
    end
    cred, zone = resolve_cloudflare_zone_in(@credentials, domain)
    return failure("No connected Cloudflare account owns #{domain}. Connect + Verify the account first.") unless zone

    r = @client_for.call(cred).upsert_dns_record(zone["id"], name: domain, content: content, type: type, proxied: proxied)
    return failure("Setting the DNS record failed: #{r.error}") unless r.ok?

    Result.new(ok: true, record: r.data,
               message: "#{type} #{domain} → #{content} set in Cloudflare (#{cred.name}); proxied: #{proxied}.")
  end

  # Delete the record for `domain` from the owning zone. Idempotent — reports OK
  # when there's already no record to delete.
  def delete!(domain:)
    return failure("A domain (record name) is required.") if domain.blank?

    cred, zone = resolve_cloudflare_zone_in(@credentials, domain)
    return failure("No connected Cloudflare account owns #{domain}. Connect + Verify the account first.") unless zone

    client = @client_for.call(cred)
    rec = client.dns_record(zone["id"], domain)
    return failure("Couldn't read the DNS record for #{domain}: #{rec.error}") unless rec.ok?
    return Result.new(ok: true, record: nil, message: "#{domain} has no DNS record in Cloudflare (already absent).") if rec.data.nil?

    r = client.delete_dns_record(zone["id"], rec.data["id"])
    return failure("Deleting the DNS record failed: #{r.error}") unless r.ok?

    Result.new(ok: true, record: rec.data, message: "Deleted #{domain} from Cloudflare (#{cred.name}).")
  end

  private

  def failure(message) = Result.new(ok: false, message: message)
end
