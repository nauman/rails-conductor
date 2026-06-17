class Organization < ApplicationRecord
  has_many :memberships, dependent: :destroy
  has_many :users, through: :memberships
  has_many :invitations, dependent: :destroy

  has_many :servers, dependent: :nullify
  has_many :apps, dependent: :nullify
  has_many :database_clusters, dependent: :destroy
  has_many :databases, dependent: :destroy
  has_many :cron_jobs, dependent: :destroy
  has_many :credentials, dependent: :nullify

  # GitHub API token (a fine-grained PAT or App installation token) for managing
  # deploy keys / webhooks on this org's repos.
  def github_token
    credentials.active.for_provider("github").first&.api_key
  end
  has_many :backups, dependent: :nullify
  has_many :ssh_keys, dependent: :nullify

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

  def onboarded?
    onboarded_at.present?
  end
end
