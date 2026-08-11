# Delete a Cloudflare DNS record by name, via an account Conductor is connected
# to. Idempotent (OK if already absent). Mutating: lives inside the write-scoped
# conductor_domain tool. Delegates to CloudflareDnsRecord#delete!.
class DeleteDnsRecordTool
  include ActorScoped
  include CloudflareActorCredentials

  DEFINITION = {
    name: "delete_dns",
    description: "Delete a Cloudflare DNS record by name (e.g. a subdomain pointing at a decommissioned host) " \
      "via a connected + Verified Cloudflare account that owns the zone. Idempotent — reports OK if already absent.",
    input_schema: {
      type: "object",
      properties: {
        domain: { type: "string", description: "The record name / FQDN to delete (e.g. old.example.com)" }
      },
      required: %w[domain]
    }
  }.freeze

  def initialize(user:)
    @user = user
  end

  def call(input)
    domain = input["domain"].to_s.strip
    return Result.fail("A domain is required.") if domain.blank?

    r = CloudflareDnsRecord.new(actor_cloudflare_credentials).delete!(domain: domain)
    return Result.fail(r.message) unless r.ok?

    Result.ok({ domain: domain, deleted: true, message: r.message, _organization: Current.organization })
  end
end
