class Credential < ApplicationRecord
  PROVIDERS = %w[cloudflare aws hetzner digitalocean stripe sendgrid github github_app].freeze

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

  # Cloudflare's hosted API MCP server (per Cloudflare's agent-setup). Auth is OAuth,
  # triggered on first tool use — no token in the command (the stored token is for
  # Conductor's OWN direct API calls: verify/zones/put-behind-Cloudflare).
  CLOUDFLARE_MCP_URL = "https://mcp.cloudflare.com/mcp".freeze

  def cloudflare? = provider == "cloudflare"
  def verified? = verified_at.present?

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

  # Client-side attach command (OAuth — no token in the command). Named per account
  # so you can add one connection per account and authorize each in its own OAuth.
  def cloudflare_mcp_command
    %(claude mcp add --transport http cloudflare-#{name.parameterize} #{CLOUDFLARE_MCP_URL})
  end
end
