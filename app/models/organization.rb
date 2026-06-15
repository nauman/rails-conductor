class Organization < ApplicationRecord
  has_many :memberships, dependent: :destroy
  has_many :users, through: :memberships

  validates :name, presence: true

  # Create an org and make the given user its owner, atomically.
  def self.create_for(user, name:)
    transaction do
      org = create!(name: name)
      org.add_member(user, role: :owner)
      org
    end
  end

  def add_member(user, role: :member)
    memberships.create!(user: user, role: role)
  end

  def owner?(user)
    memberships.exists?(user: user, role: :owner)
  end
end
