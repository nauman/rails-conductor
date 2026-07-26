# App-transfer spec 26, Slice 2. Materializes the dedicated-container DB model
# for an app: stands up `<app>-db` (Postgres container + volume + network),
# registers it as a DatabaseCluster, and provisions the app's database on it.
# The result is a self-contained, portable unit — the whole point of the
# dedicated model (Decision A). Idempotent: safe to re-run.
#
# Placement (Decision A): `colocated` puts the container on the app's own server;
# `dedicated_host` targets a separate DB server passed as `server:`. The default
# is colocated on the app's server.
class DedicatedDbProvisioner
  class NotDedicated < StandardError; end
  class NoServer < StandardError; end

  def initialize(app:, server: nil, container_client: nil, sql_client: nil, image: PostgresContainerClient::DEFAULT_IMAGE)
    @app = app
    @server = server || app.server
    @container_client = container_client
    @sql_client = sql_client
    @image = image
  end

  def provision!
    raise NotDedicated, "app #{@app.slug} is not in dedicated database_mode" unless @app.dedicated_db?
    raise NoServer, "no target server for #{@app.slug}'s dedicated DB" unless @server

    cluster = find_or_create_cluster!
    existing = cluster.databases.find_by(app: @app)
    return existing if existing&.status == "active"

    cluster.provision_database!(name: @app.database_base_name, app: @app, client: @sql_client)
  end

  private

  def find_or_create_cluster!
    existing = @app.organization.database_clusters
                   .find_by(server: @server, container_name: @app.dedicated_db_container_name)
    return existing if existing

    admin_password = SecureRandom.hex(24)
    container_client.create!(
      container_name: @app.dedicated_db_container_name,
      volume: @app.dedicated_db_volume,
      network: @app.dedicated_db_network,
      admin_username: ADMIN_USERNAME,
      admin_password: admin_password,
      image: @image
    )

    @app.organization.database_clusters.create!(
      server: @server,
      name: @app.dedicated_db_container_name,
      container_name: @app.dedicated_db_container_name,
      admin_username: ADMIN_USERNAME,
      admin_password: admin_password,
      port: 5432
    )
  end

  ADMIN_USERNAME = "conductor".freeze

  def container_client
    @container_client ||= PostgresContainerClient.new(@server)
  end
end
