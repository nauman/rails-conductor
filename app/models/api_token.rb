class ApiToken < ApplicationRecord
  belongs_to :user
  belongs_to :organization, optional: true

  validates :name, presence: true
  validates :token_digest, presence: true, uniqueness: true
  # When a token is bound to an org, its user must be a member of that org.
  # Org-less tokens are allowed (they fall back to the user's first org at
  # request time), so this only fires when an organization is present.
  validate :user_must_belong_to_organization
  # An org-less token falls back to the user's first org at request time, so a
  # deploy (write) scope on it would apply to whatever org it lands on. Forbid
  # that combination at the model level — org-less tokens are read-only for every
  # caller (console, API issuance, future flows), not just the one-time cleanup.
  validate :org_less_tokens_are_read_only

  # Generate a new API token for a user.
  # Returns [raw_token, api_token_record].
  # The raw token is shown once and cannot be retrieved again.
  # Pass an optional organization to scope the token; otherwise it falls back
  # to the user's first organization when the API resolves the request org.
  SCOPES = %w[deploy read].freeze
  validates :scope, inclusion: { in: SCOPES }

  def self.generate(user:, name:, organization: nil, scope: "deploy")
    raw_token = SecureRandom.urlsafe_base64(32)
    digest = Digest::SHA256.hexdigest(raw_token)

    # Without a bound org, write scope is unsafe (see the validation) — coerce to
    # read so the default-deploy signature can't silently mint an org-less writer.
    scope = "read" if organization.nil?

    record = create!(user: user, name: name, token_digest: digest,
                     organization: organization, scope: scope)
    [raw_token, record]
  end

  def read_only? = scope == "read"

  # Authenticate a raw token string.
  # Returns the ApiToken record if valid, nil otherwise.
  # Updates last_used_at on successful authentication.
  def self.authenticate(raw_token)
    return nil if raw_token.blank?

    digest = Digest::SHA256.hexdigest(raw_token)
    token = find_by(token_digest: digest)
    token&.touch(:last_used_at)
    token
  end

  private

  def user_must_belong_to_organization
    return if organization.nil? || user.nil?
    return if user.organizations.exists?(organization.id)

    errors.add(:organization, "must be one the user belongs to")
  end

  def org_less_tokens_are_read_only
    return unless organization.nil? && scope == "deploy"

    errors.add(:scope, "deploy requires an organization; org-less tokens are read-only")
  end
end
