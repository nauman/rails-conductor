# Create or update a Cloudflare DNS record (A/CNAME) via an account Conductor is
# already connected to — no vault/token handling. Mutating: needs an
# operator/deploy-scoped token. Idempotent (upsert). Delegates to CloudflareDnsRecord.
class SetDnsRecordTool
  include ActorScoped
  include CloudflareActorCredentials

  DEFINITION = {
    name: "set_dns",
    description: "Create or update a Cloudflare DNS record (A/CNAME) for a domain in a connected + Verified " \
      "Cloudflare account that owns the zone. Idempotent — updates the record if it exists, else creates it. " \
      "proxied=false (default) = DNS-only (grey cloud); true = proxied (orange).",
    input_schema: {
      type: "object",
      properties: {
        domain:  { type: "string",  description: "The record name / FQDN (e.g. old.platepose.com)" },
        content: { type: "string",  description: "Target: an IP for type=A, or a hostname for type=CNAME" },
        type:    { type: "string",  description: "Record type (default A). One of: A, CNAME" },
        proxied: { type: "boolean", description: "Proxy through Cloudflare (orange cloud)? Default false (DNS-only)" }
      },
      required: %w[domain content]
    }
  }.freeze

  def initialize(user:)
    @user = user
  end

  def call(input)
    domain  = input["domain"].to_s.strip
    content = input["content"].to_s.strip
    return Result.fail("Both domain and content are required.") if domain.blank? || content.blank?

    type    = input["type"].presence || "A"
    proxied = input["proxied"] == true

    r = CloudflareDnsRecord.new(actor_cloudflare_credentials)
                           .set!(domain: domain, content: content, type: type, proxied: proxied)
    return Result.fail(r.message) unless r.ok?

    Result.ok({
      domain: domain,
      type: type.upcase,
      content: content,
      proxied: proxied,
      message: r.message,
      _organization: Current.organization
    })
  end
end
