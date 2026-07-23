class Credential < ApplicationRecord
  PROVIDERS = %w[cloudflare amazon_ses aws hetzner digitalocean stripe sendgrid github github_app].freeze

  belongs_to :organization, optional: true

  encrypts :api_key
  encrypts :api_secret

  has_many :backups, dependent: :nullify

  validates :name, presence: true
  validates :provider, presence: true, inclusion: { in: PROVIDERS }

  scope :active, -> { where(active: true) }
  scope :inactive, -> { where(active: false) }
  scope :for_provider, ->(provider) { where(provider: provider) }

  def masked_api_key
    return "•••••••" if api_key.blank?
    "#{api_key[0..3]}•••••#{api_key[-4..]}"
  end

  def masked_api_secret
    return nil if api_secret.blank?
    "#{api_secret[0..3]}•••••#{api_secret[-4..]}"
  end

  # --- Cloudflare connections (multi-account) ---

  # Cloudflare exposes ~15 capability-scoped hosted MCP servers. We deliberately attach
  # ONLY the read/diagnose ones — never the broad `mcp.cloudflare.com/mcp` aggregate or
  # the mutating `bindings` (Workers deploy/delete) / DNS-edit / cache-purge servers.
  #
  # The security model mirrors Conductor's sudo wrappers: agents get a non-destructive
  # surface for diagnosis, and every CONFIG MUTATION we actually need (turn the proxy
  # on, set SSL mode) flows through Conductor's own narrow, audited `CloudflareClient`
  # — NOT through MCP. Auth is OAuth on first tool use; no token in the attach command
  # (the stored token is for Conductor's OWN direct calls: verify/zones/put-behind).
  CLOUDFLARE_MCP_SERVERS = {
    "docs"          => "https://docs.mcp.cloudflare.com/mcp",            # docs (no auth)
    "dns-analytics" => "https://dns-analytics.mcp.cloudflare.com/mcp",   # zone/DNS analytics (read)
    "observability" => "https://observability.mcp.cloudflare.com/mcp",   # logs/metrics (read)
    "graphql"       => "https://graphql.mcp.cloudflare.com/mcp",         # analytics GraphQL (read)
    "radar"         => "https://radar.mcp.cloudflare.com/mcp"            # internet insights (read)
  }.freeze

  def cloudflare? = provider == "cloudflare"
  def ses? = provider == "amazon_ses"
  def verifiable? = cloudflare? || ses?
  def verified? = verified_at.present?

  # Amazon SES (SMTP): api_key = SMTP username, api_secret = SMTP password, region →
  # host, endpoint = optional host override. Verify does a real SMTP auth.
  def verify_ses!(client: nil)
    client ||= SesClient.new(api_key, api_secret, region, endpoint: endpoint)
    r = client.verify
    return r.error unless r.ok?

    update!(verified_at: Time.current)
    nil
  end

  def zones_list
    JSON.parse(zones.presence || "[]")
  rescue JSON::ParserError
    []
  end

  # Verify the token by LISTING ZONES — which is what we actually need, and works for
  # every valid token. (We deliberately do NOT gate on /user/tokens/verify: that
  # user-scoped endpoint returns "Invalid API Token" for account-scoped tokens that
  # are perfectly valid for zone operations.) Caches account id + zones so Conductor
  # can resolve which connected account owns a domain. Returns nil on success, else
  # an error string.
  def verify_cloudflare!(client: nil)
    client ||= CloudflareClient.new(api_key)
    z = client.zones
    return z.error unless z.ok?

    update!(account_id: z.data.first&.dig("account_id"), zones: z.data.to_json, verified_at: Time.current)
    nil
  end

  # Client-side attach commands (OAuth — no token in the command), one per read-only
  # scoped server. Named per account + capability so you can attach one connection per
  # account and authorize each in its own OAuth flow. Returns the list of commands.
  def cloudflare_mcp_commands
    slug = name.parameterize
    CLOUDFLARE_MCP_SERVERS.map do |cap, url|
      %(claude mcp add --transport http cf-#{slug}-#{cap} #{url})
    end
  end

  # Backwards-compatible single string (all attach commands, newline-joined).
  def cloudflare_mcp_command
    cloudflare_mcp_commands.join("\n")
  end
end
