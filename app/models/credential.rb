class Credential < ApplicationRecord
  PROVIDERS = %w[cloudflare amazon_ses aws hetzner digitalocean stripe sendgrid github github_app].freeze

  belongs_to :organization, optional: true

  encrypts :api_key
  encrypts :api_secret

  # Secrets are never RENDERED (they are encrypted, and the form shows a masked
  # placeholder), so an edit form necessarily posts an empty field unless the
  # operator retypes the value. Assigning that empty string used to overwrite the
  # stored secret — silently. Renaming a credential, fixing an endpoint or
  # changing a region would destroy the key pair, report success, and leave
  # nothing to indicate the credential was now broken.
  #
  # That is how a working S3 key pair becomes half a key pair. The resulting
  # upload failures then went unnoticed for weeks because a failed upload was
  # being recorded as a successful backup.
  #
  # So a blank assignment on a PERSISTED record means "unchanged", not "clear".
  # Clearing stays possible — see #clear_api_secret! — but has to be asked for.
  SECRET_FIELDS = %i[api_key api_secret].freeze

  SECRET_FIELDS.each do |field|
    define_method("#{field}=") do |value|
      return if persisted? && value.blank? && self[field].present?

      super(value)
    end
  end

  def clear_api_secret! = update_column(:api_secret, nil)
  def clear_api_key!    = update_column(:api_key, nil)

  has_many :backups, dependent: :nullify

  validates :name, presence: true
  validates :provider, presence: true, inclusion: { in: PROVIDERS }
  # SES SMTP passwords are region-specific — a blank region silently defaults to
  # us-east-1 and produces a misleading 535. Force it to be set.
  validates :region, presence: { message: "is required for SES (the AWS region where the SMTP credentials were created)" }, if: :ses?
  # A region, not a host. Pasting the SMTP endpoint here (`email-smtp.<region>.amazonaws.com`)
  # is an easy mistake and fails silently: SesClient interpolates it into
  # `email-smtp.#{region}.amazonaws.com`, so Verify dials a doubled hostname that
  # resolves to nothing. Caught in production once.
  # Format-only, deliberately: it rejects hostnames (dots can't match) without
  # pinning a region list that AWS keeps extending. The first segment is [a-z]+,
  # not [a-z]{2}, so longer prefixes like eusc-de-east-1 still pass.
  AWS_REGION = /\A[a-z]+(-[a-z]+)+-\d+\z/
  validates :region,
            format: { with: AWS_REGION,
                      message: "must be an AWS region like ap-southeast-2, not a hostname " \
                               "(put a custom SMTP host in Endpoint instead)" },
            if: -> { ses? && region.present? }

  scope :active, -> { where(active: true) }
  scope :inactive, -> { where(active: false) }
  scope :for_provider, ->(provider) { where(provider: provider) }

  # Rotating the credential invalidates what we knew about it. `verified?` must
  # describe THESE values, not the ones that passed Verify a month ago — and the
  # cached account_id/zones may belong to an account the new token can't reach.
  # Without this, swapping a token silently inherits the old proof.
  before_save :invalidate_verification, if: :identity_changed?

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

  # The fields that make a credential a different credential — i.e. what an
  # operator types. Region/endpoint count: SES SMTP passwords are region-derived,
  # so the same key/secret against a new region is an unproven combination.
  # `account_id` and `zones` are deliberately NOT here: Verify derives them, and
  # including them would make this callback erase the verification it just wrote.
  IDENTITY_FIELDS = %w[api_key api_secret region endpoint].freeze

  def identity_changed?
    persisted? && (changed & IDENTITY_FIELDS).any?
  end

  def invalidate_verification
    # account_id is part of the identity, so only clear what Verify derived:
    # the timestamp and the cached zone list.
    self.verified_at = nil
    self.zones = nil
  end

  # Amazon SES (SMTP): api_key = SMTP username, api_secret = SMTP password, region →
  # host, endpoint = optional host override. Verify does a real SMTP auth.
  def verify_ses!(client: nil)
    # Check the record BEFORE dialling. A row saved before the region format rule
    # existed can still hold a hostname: connecting would fail on a doubled host
    # anyway, and if a custom endpoint made AUTH succeed, the update! below would
    # raise RecordInvalid and 500 instead of telling the operator what's wrong.
    return errors.full_messages.to_sentence unless valid?

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
  def verify_cloudflare!(client: nil, allow_empty: false)
    client ||= CloudflareClient.new(api_key)
    z = client.zones
    return z.error unless z.ok?

    # AN EMPTY RESULT IS SUSPICIOUS ONCE, AND THE WORLD TWICE.
    #
    # A token whose scope was narrowed returns SUCCESS with an empty list, and writing
    # that erases every zone into a state indistinguishable from an account that owns
    # nothing — unattended, on a schedule.
    #
    # But refusing it unconditionally was worse in the other direction: an account
    # whose zones really were all deleted or transferred could NEVER re-verify, and
    # its stale list went on driving proxyable_apps with no way out but recreating the
    # credential. A permanent veto is not a safety property, it is a wedge.
    #
    # So: the first empty is refused and reported, the second consecutive one is
    # believed. Any non-empty result clears the count, so two empties months apart
    # never add up to a wipe.
    # A POPULATED→EMPTY TRANSITION IS NEVER APPLIED AUTOMATICALLY.
    #
    # A narrowed token returns SUCCESS with zero zones — and it will do so on every
    # scheduled refresh, so counting observations does not distinguish "the zones are
    # gone" from "we can no longer see them". Two-strikes only delayed the wipe by one
    # cycle; the ambiguity is not resolvable by repetition, because the signal is
    # identical either way.
    #
    # So an automated refresh may only ever ADD or CHANGE zones, never empty the list.
    # A human clears it deliberately (`allow_empty: true`), which is the one thing a
    # narrowed token cannot do on its own. Stale is recoverable; silently empty is not,
    # and "eventually empty" is just silently empty with a delay.
    if z.data.empty? && zones_list.any? && !allow_empty
      count = consecutive_empty_zone_reads.to_i + 1
      update_columns(consecutive_empty_zone_reads: count)
      return "Cloudflare returned zero zones while #{zones_list.length} are cached (#{count} time#{'s' if count > 1} " \
             "in a row). Refusing to empty the list automatically — a narrowed token scope and a genuinely " \
             "emptied account look identical from here, and only one of them is recoverable. The cached list " \
             "is kept. Check the token's Zone Resources; if the zones really are gone, verify with " \
             "allow_empty to clear it deliberately."
    end

    update!(account_id: z.data.first&.dig("account_id"), zones: z.data.to_json, verified_at: Time.current)
    update_columns(consecutive_empty_zone_reads: 0)
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
