# Convert an app IN PLACE from shared-cluster DB → dedicated container, so it
# becomes the portable unit AppTransfer (spec 26) requires. Same box, colocated,
# Kamal only for now. The App model calls the two modes "convertible live"; this
# is that conversion.
#
# Order is chosen so the switch is REVERSIBLE until the operator commits:
#   1. provision the dedicated `<slug>-db` container (DedicatedDbProvisioner)
#   2. copy the app's data shared → dedicated (DatabaseReplicator, same server)
#   3. drop the manual DATABASE_URL env var so the DERIVED dedicated DSN takes over
#      at the next deploy (App#derived_database_url)
# The SHARED database is left INTACT — nothing is dropped — so a failed or
# unverified conversion can be rolled back by flipping the mode and restoring the
# DATABASE_URL env var. The caller performs the redeploy (explicit, supervised) and
# verifies before decommissioning the shared copy.
class SharedToDedicatedConverter
  class Error < StandardError; end

  Result = Struct.new(:ok, :message, :data, keyword_init: true) do
    def ok? = ok
  end

  def initialize(app, provisioner_for: nil, replicator_for: nil, clock: -> { Time.now.utc })
    @app = app
    @provisioner_for = provisioner_for || ->(a) { DedicatedDbProvisioner.new(app: a) }
    @replicator_for = replicator_for
    @clock = clock
  end

  # credential/bucket/provider stage the copy through object storage (same path as
  # the transfer). They may be derived from the app's own R2 config by the caller.
  def call(credential:, bucket:, provider: "cloudflare_r2")
    guard = preflight
    return guard if guard

    source_url = shared_database_url
    return failure("app has no DATABASE_URL env var to convert from") if source_url.blank?

    prior_mode = @app.database_mode
    prior_placement = @app.database_placement

    @app.update!(database_mode: "dedicated", database_placement: "colocated")
    database = @provisioner_for.call(@app).provision!
    target_url = database.database_url

    copy_data!(source_url: source_url, target_url: target_url, credential: credential, bucket: bucket, provider: provider)

    # Hand DATABASE_URL back to the derived dedicated DSN. The manual (shared) env
    # var is removed only after the copy succeeds — until here, rollback is a no-op.
    @app.env_variables.where(key: "DATABASE_URL").destroy_all

    Result.new(ok: true,
               message: "#{@app.slug} converted to a dedicated DB (#{database.database_cluster.container_name}). " \
                        "Data copied; DATABASE_URL now derives the dedicated DSN. REDEPLOY to cut over, verify, then " \
                        "decommission the shared copy.",
               data: { app: @app.slug, dedicated_container: database.database_cluster.container_name,
                       next: "deploy #{@app.slug}, verify, then drop the shared database", reversible_until_redeploy: true })
  rescue StandardError => e
    # Roll the mode back so we never leave a half-converted app the executor would
    # then try to transfer. The dedicated container/data (if created) is harmless
    # and idempotently reused on a retry; the shared DB was never touched.
    @app.update!(database_mode: prior_mode, database_placement: prior_placement) if prior_mode
    failure("conversion failed (rolled back to #{prior_mode}): #{e.message}")
  end

  private

  def preflight
    return failure("#{@app.slug} is already dedicated") if @app.dedicated_db?
    return failure("conversion is Kamal-only for now — #{@app.slug} deploys via #{@app.deploy_method}") unless @app.kamal?
    return failure("conversion targets colocated placement — #{@app.slug} is #{@app.database_placement}") unless @app.colocated_db?
    return failure("no server for #{@app.slug}") unless @app.server
    nil
  end

  def shared_database_url
    @app.env_variables.find_by(key: "DATABASE_URL")&.value
  end

  def copy_data!(source_url:, target_url:, credential:, bucket:, provider:)
    key = "db-convert/#{@app.slug}-#{@clock.call.strftime('%Y%m%d%H%M%S')}.sql.gz"
    replicator = if @replicator_for
      @replicator_for.call(source_url: source_url, target_url: target_url, credential: credential, bucket: bucket, object_key: key, provider: provider)
    else
      DatabaseReplicator.new(
        source_server: @app.server, source_url: source_url,
        target_server: @app.server, target_url: target_url,
        credential: credential, bucket: bucket, object_key: key, provider: provider
      )
    end
    replicator.run!
  end

  def failure(message) = Result.new(ok: false, message: message)
end
