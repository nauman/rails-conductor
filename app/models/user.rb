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
      create!(email: normalized_email, admin: true)
    else
      find_by(email: normalized_email)
    end
  end

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
