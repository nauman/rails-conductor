class ApiToken < ApplicationRecord
  belongs_to :user
  belongs_to :organization, optional: true

  validates :name, presence: true
  validates :token_digest, presence: true, uniqueness: true
  # When a token is bound to an org, its user must be a member of that org.
  # Org-less tokens are allowed (they fall back to the user's first org at
  # request time), so this only fires when an organization is present.
  validate :user_must_belong_to_organization

  # Generate a new API token for a user.
  # Returns [raw_token, api_token_record].
  # The raw token is shown once and cannot be retrieved again.
  # Pass an optional organization to scope the token; otherwise it falls back
  # to the user's first organization when the API resolves the request org.
  def self.generate(user:, name:, organization: nil)
    raw_token = SecureRandom.urlsafe_base64(32)
    digest = Digest::SHA256.hexdigest(raw_token)

    record = create!(user: user, name: name, token_digest: digest, organization: organization)
    [raw_token, record]
  end

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
end
