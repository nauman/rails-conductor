class ApiToken < ApplicationRecord
  belongs_to :user

  validates :name, presence: true
  validates :token_digest, presence: true, uniqueness: true

  # Generate a new API token for a user.
  # Returns [raw_token, api_token_record].
  # The raw token is shown once and cannot be retrieved again.
  def self.generate(user:, name:)
    raw_token = SecureRandom.urlsafe_base64(32)
    digest = Digest::SHA256.hexdigest(raw_token)

    record = create!(user: user, name: name, token_digest: digest)
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
end
