class Database < ApplicationRecord
  STATUSES = %w[pending active error].freeze

  belongs_to :organization
  belongs_to :database_cluster
  belongs_to :app, optional: true

  encrypts :password

  validates :name, :username, presence: true
  validates :status, inclusion: { in: STATUSES }

  # Connection URL for the app's deploy config. Host is the cluster's container
  # name (reachable on the shared docker network).
  def database_url
    "postgres://#{username}:#{password}@#{database_cluster.container_name}:#{database_cluster.port}/#{name}"
  end
end
