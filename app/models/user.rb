class User < ApplicationRecord
  validates :email, presence: true, uniqueness: { case_sensitive: false }

  passwordless_with :email

  scope :admins, -> { where(admin: true) }

  # Sign-in is invite-only. The very first user bootstraps as the platform
  # admin (webmaster); after that, only existing users can request a magic link
  # — unknown emails get nothing (no auto-signup, no user enumeration).
  def self.fetch_resource_for_passwordless(email)
    normalized_email = email.downcase.strip

    if User.count.zero?
      create!(email: normalized_email, admin: true).tap(&:ensure_personal_organization!)
    else
      find_by(email: normalized_email)
    end
  end

  # Every user belongs to at least one organization. Creates a personal org
  # (owned by the user) if they don't yet belong to any.
  def ensure_personal_organization!
    return organizations.first if organizations.any?

    Organization.create_for(self, name: email.split("@").first)
  end

  has_many :memberships, dependent: :destroy
  has_many :organizations, through: :memberships
  has_many :api_tokens, dependent: :destroy
  has_many :conversations, dependent: :destroy

  def admin? = admin

  def can?(action, record)
    permission_for(record).can?(action)
  end

  private

  def permission_for(record)
    case record
    when :conversation, Conversation
      ConversationPermission.new(user: self, record: record.is_a?(Conversation) ? record : nil)
    else
      raise ArgumentError, "No permission class for #{record.class}"
    end
  end
end
