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
  # The host is the cluster's ASSIGNED alias, not its container name (ADR 0011).
  # A container name is a display value an operator can retype; this URL is
  # re-derived on every deploy, so a rename used to break the next one silently.
  def database_url
    "postgres://#{username}:#{password}@#{database_cluster.connect_host}:#{database_cluster.port}/#{name}"
  end
end
