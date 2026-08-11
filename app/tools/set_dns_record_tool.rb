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
        domain:  { type: "string",  description: "The record name / FQDN (e.g. old.example.com)" },
        content: { type: "string",  description: "Target: an IP for A, a hostname for CNAME/MX, or the full value for TXT (SPF/DKIM/verification tokens)" },
        type:    { type: "string",  description: "Record type (default A). One of: A, AAAA, CNAME, TXT, MX" },
        priority: { type: "integer", description: "MX priority (0-65535), REQUIRED for type=MX and rejected for any other type. E.g. 10 for an SES custom MAIL-FROM bounce host." },
        proxied: { type: "boolean", description: "Proxy through Cloudflare (orange cloud)? Default false. Only valid for A/AAAA/CNAME — TXT and MX cannot be proxied." }
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

    type     = input["type"].presence || "A"
    priority = input["priority"]
    proxied = input["proxied"] == true

    r = CloudflareDnsRecord.new(actor_cloudflare_credentials)
                           .set!(domain: domain, content: content, type: type,
                                 proxied: proxied, priority: priority)
    return Result.fail(r.message) unless r.ok?

    Result.ok({
      domain: domain,
      type: type.upcase,
      content: content,
      priority: (priority if type.to_s.upcase == "MX"),
      proxied: proxied,
      message: r.message,
      _organization: Current.organization
    })
  end
end
