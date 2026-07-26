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
  class Unreachable < StandardError; end

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
    ensure_reachable!

    cluster = ensure_cluster_and_container!
    existing = cluster.databases.find_by(app: @app)
    return existing if existing&.status == "active"

    # A non-active record is a prior failed/pending attempt — discard it so a
    # retry reconciles instead of piling up duplicate Database rows.
    existing&.destroy
    cluster.provision_database!(name: @app.database_base_name, app: @app, client: @sql_client)
  end

  private

  # A colocated dedicated DB is reachable only if the app shares a Docker network
  # with it. Refuse the cases we can't yet make reachable rather than provision an
  # island: dedicated_host (a bridge network can't span boxes — needs a routable
  # endpoint) and non-Kamal apps (their network wiring isn't built yet).
  def ensure_reachable!
    unless @app.colocated_db?
      raise Unreachable, "#{@app.slug}: dedicated_host placement needs a cross-box routable endpoint — not wired yet; use colocated"
    end
    unless @app.deploy_network
      raise Unreachable, "#{@app.slug}: reachability for #{@app.deploy_method} apps isn't wired yet — only Kamal apps share a network with their DB"
    end
  end

  # Persist the cluster (with its admin password) FIRST, then ensure the
  # container exists using that persisted password. This makes retries safe: a
  # crash after the container is created but before the row is saved can't happen
  # (row is saved first), and re-running reuses the same password rather than
  # generating a new one the running container would reject.
  def ensure_cluster_and_container!
    cluster = @app.organization.database_clusters.find_or_create_by!(
      server: @server, container_name: @app.dedicated_db_container_name
    ) do |c|
      c.name = @app.dedicated_db_container_name
      c.admin_username = ADMIN_USERNAME
      c.admin_password = SecureRandom.hex(24)
      c.port = 5432
    end

    container_client.create!(
      container_name: @app.dedicated_db_container_name,
      volume: @app.dedicated_db_volume,
      network: @app.deploy_network,
      admin_username: cluster.admin_username,
      admin_password: cluster.admin_password,
      image: @image
    )

    cluster
  end

  ADMIN_USERNAME = "conductor".freeze

  def container_client
    @container_client ||= PostgresContainerClient.new(@server)
  end
end
