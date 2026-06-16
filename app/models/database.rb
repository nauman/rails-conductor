class Database < ApplicationRecord
  STATUSES = %w[pending active error].freeze

  belongs_to :organization
  belongs_to :database_cluster
  belongs_to :app, optional: true

  encrypts :password

  validates :name, :username, presence: true
  validates :status, inclusion: { in: STATUSES }
end
