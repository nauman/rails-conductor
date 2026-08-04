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
  # MX matters for email deliverability: SES/Postmark custom MAIL-FROM needs an
  # MX at the bounce subdomain, and without it that setup had to be clicked into
  # the Cloudflare dashboard by hand — outside Conductor's audit trail entirely.
  SUPPORTED_TYPES = %w[A AAAA CNAME TXT MX].freeze

  # Cloudflare requires a priority on MX and rejects one anywhere else.
  PRIORITY_TYPE = "MX".freeze
  PRIORITY_RANGE = (0..65_535)

  # Only address-shaped records can sit behind Cloudflare's proxy. Asking to
  # proxy a TXT record is an API error, so refuse it here with a reason rather
  # than forwarding a request that cannot succeed.
  PROXYABLE_TYPES = %w[A AAAA CNAME].freeze

  def set!(domain:, content:, type: "A", proxied: false, priority: nil)
    return failure("A domain (record name) is required.") if domain.blank?
    return failure("A content value is required (an IP for A, a hostname for CNAME, the value for TXT/MX).") if content.blank?

    type = type.to_s.upcase
    unless SUPPORTED_TYPES.include?(type)
      return failure("Unsupported record type #{type}. Supported: #{SUPPORTED_TYPES.join(', ')}.")
    end

    if (err = validate_priority(type, priority))
      return failure(err)
    end

    if proxied && !PROXYABLE_TYPES.include?(type)
      return failure("#{type} records cannot be proxied through Cloudflare — set proxied: false.")
    end
    cred, zone = resolve_cloudflare_zone_in(@credentials, domain)
    return failure("No connected Cloudflare account owns #{domain}. Connect + Verify the account first.") unless zone

    r = @client_for.call(cred).upsert_dns_record(zone["id"], name: domain, content: content,
                                                 type: type, proxied: proxied,
                                                 priority: (priority&.to_i if type == PRIORITY_TYPE))
    return failure("Setting the DNS record failed: #{r.error}") unless r.ok?

    detail = type == PRIORITY_TYPE ? "priority #{priority.to_i}" : "proxied: #{proxied}"
    Result.new(ok: true, record: r.data,
               message: "#{type} #{domain} → #{content} set in Cloudflare (#{cred.name}); #{detail}.")
  end

  # Delete the record for `domain` from the owning zone. Idempotent — reports OK
  # when there's already no record to delete.
  def delete!(domain:)
    return failure("A domain (record name) is required.") if domain.blank?

    cred, zone = resolve_cloudflare_zone_in(@credentials, domain)
    return failure("No connected Cloudflare account owns #{domain}. Connect + Verify the account first.") unless zone

    client = @client_for.call(cred)
    # ALL records at this name. Deleting only the first and reporting success
    # would leave the name resolving — the worst kind of result for a
    # destructive action, because the caller believes it is done.
    recs = client.dns_records(zone["id"], domain)
    return failure("Couldn't read the DNS records for #{domain}: #{recs.error}") unless recs.ok?

    found = Array(recs.data)
    if found.empty?
      return Result.new(ok: true, record: nil,
                        message: "#{domain} has no DNS record in Cloudflare (already absent).")
    end

    found.each do |rec|
      r = client.delete_dns_record(zone["id"], rec["id"])
      return failure("Deleting the #{rec['type']} record for #{domain} failed: #{r.error}") unless r.ok?
    end

    types = found.map { |r| r["type"] }.tally.map { |t, n| n > 1 ? "#{n}×#{t}" : t }.join(", ")
    Result.new(ok: true, record: found.first,
               message: "Deleted #{domain} from Cloudflare (#{cred.name}) — #{found.size} record(s): #{types}.")
  end

  private

  # Refuse locally rather than forwarding a request Cloudflare will reject — and
  # never silently DROP a priority the caller supplied, because they would
  # believe it was applied.
  def validate_priority(type, priority)
    if type == PRIORITY_TYPE
      return "An MX record needs a priority (e.g. 10)." if priority.blank?
      unless priority.to_s.match?(/\A\d+\z/) && PRIORITY_RANGE.cover?(priority.to_i)
        return "MX priority must be a whole number between #{PRIORITY_RANGE.first} and #{PRIORITY_RANGE.last}."
      end
    elsif priority.present?
      return "A priority applies only to MX records, not #{type}."
    end
    nil
  end

  def failure(message) = Result.new(ok: false, message: message)
end
