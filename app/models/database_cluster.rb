class DatabaseCluster < ApplicationRecord
  belongs_to :organization
  belongs_to :server
  has_many :databases, dependent: :destroy

  encrypts :admin_password

  validates :name, :container_name, :admin_username, presence: true

  # Provision a new database (role + database + generated password) on this
  # cluster, recording it as a Database. `client:` is injectable for tests.
  def provision_database!(name:, username: nil, app: nil, client: nil)
    username ||= name
    password = SecureRandom.hex(24)
    database = databases.create!(
      organization: organization, app: app,
      name: name, username: username, password: password, status: "pending"
    )

    (client || PostgresClusterClient.new(self)).create_database(
      name: name, username: username, password: password
    )
    database.update!(status: "active")
    database
  rescue StandardError
    database&.update(status: "error")
    raise
  end
end
