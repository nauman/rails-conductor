class Membership < ApplicationRecord
  belongs_to :user
  belongs_to :organization

  enum :role, { member: 0, owner: 1 }, default: :member

  validates :user_id, uniqueness: { scope: :organization_id }
end
