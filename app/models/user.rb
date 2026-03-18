class User < ApplicationRecord
  validates :email, presence: true, uniqueness: { case_sensitive: false }

  passwordless_with :email

  scope :admins, -> { where(admin: true) }

  # Auto-create users on sign-in. First user becomes admin.
  def self.fetch_resource_for_passwordless(email)
    normalized_email = email.downcase.strip
    is_first_user = User.count.zero?

    find_or_create_by!(email: normalized_email) do |user|
      user.admin = is_first_user
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
