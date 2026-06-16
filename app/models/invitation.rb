class Invitation < ApplicationRecord
  belongs_to :organization
  belongs_to :invited_by, class_name: "User"

  has_secure_token

  enum :role, { member: 0, owner: 1 }, default: :member

  validates :email, presence: true

  scope :pending, -> { where(accepted_at: nil) }

  def pending?
    accepted_at.nil?
  end

  # Add the user to the organization with the invited role (idempotent) and
  # mark the invitation accepted.
  def accept!(user)
    transaction do
      organization.memberships.find_or_create_by!(user: user) { |m| m.role = role }
      update!(accepted_at: Time.current)
    end
  end
end
