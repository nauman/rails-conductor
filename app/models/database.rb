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
  # The app's deploy network is what it will resolve the host FROM, so the alias
  # only counts if it was observed there. Falls back to the app's own network, and
  # to no constraint when there is no app — in which case connect_host answers with
  # whatever it has, which is the conservative container name until an alias exists.
  def database_url(network: app&.deploy_network)
    host = database_cluster.connect_host(network: network)
    "postgres://#{username}:#{password}@#{host}:#{database_cluster.port}/#{name}"
  end
end
