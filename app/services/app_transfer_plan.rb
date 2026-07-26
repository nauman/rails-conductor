# App-transfer spec 26, Part 3 (Slice 5): the dry-run. Reconciles an app against
# a target server across every axis (compute, database, edge, DNS) and emits the
# exact change set WITHOUT mutating anything — the artifact an operator/agent
# reviews before running the transfer. The executing orchestrator (a later slice)
# runs these same phases for real.
class AppTransferPlan
  class InvalidTarget < StandardError; end

  attr_reader :app, :source_server, :target_server

  def initialize(app:, target_server:)
    @app = app
    @source_server = app.server
    @target_server = target_server
  end

  # Validates the move is coherent, then exposes the plan. Read-only.
  def call
    raise InvalidTarget, "#{app.slug} has no source server" unless source_server
    raise InvalidTarget, "target must differ from the source server" if target_server.nil? || target_server.id == source_server.id

    self
  end

  def steps
    @steps ||= [ compute_step, database_step, edge_step, cutover_step, drain_step ]
  end

  def warnings
    @warnings ||= build_warnings
  end

  def to_h
    {
      app: app.slug,
      source: { server: source_server&.name, edge: source_server&.edge_type },
      target: { server: target_server.name, edge: target_server.edge_type },
      database: { mode: app.database_mode, placement: app.database_placement },
      steps: steps,
      warnings: warnings
    }
  end

  private

  def compute_step
    step("compute", "redeploy",
         "Deploy #{app.slug} (#{app.deploy_method}) to #{target_server.name} from " \
         "#{app.repository_url}@#{app.branch}; source stays live until cut-over.")
  end

  def database_step
    detail =
      if app.dedicated_db?
        "Provision the dedicated container #{app.dedicated_db_container_name} on #{db_target} " \
        "(#{app.database_placement} placement); cold base-backup/restore from the source " \
        "#{app.dedicated_db_container_name} (Decision D). Keep the source DB as a rollback snapshot."
      else
        "Replicate the shared-cluster database via DatabasePull (pg_dump → restore) into " \
        "#{target_server.name}'s cluster."
      end
    step("database", "replicate", detail)
  end

  def edge_step
    step("edge", "publish",
         "Publish #{app.domain || '(no domain)'} on #{target_server.name}'s edge " \
         "(#{source_server.edge_type} → #{target_server.edge_type}) via Edge.for(target).")
  end

  def cutover_step
    step("cutover", "cut-over",
         "Repoint #{app.domain || 'DNS'} to #{target_server.ip_address} (Cloudflare if CF-managed), " \
         "final DB sync, switch DATABASE_URL to the target DB, let the target edge mint TLS.")
  end

  def drain_step
    step("drain", "decommission",
         "After a hold window, stop #{app.slug} on #{source_server.name} and retain its DB " \
         "snapshot for N days. (Clone = stop before this step, leaving the source live.)")
  end

  def db_target
    app.colocated_db? ? target_server.name : "the dedicated DB host"
  end

  def build_warnings
    warnings = []
    if target_server.edge_type == "kamal_proxy"
      warnings << "Target edge is kamal-proxy — Edge::KamalProxyAdapter is pending (owned by " \
                  "conductor-deployer); the edge cut-over on the target will not apply until it lands."
    elsif !%w[caddy kamal_proxy].include?(target_server.edge_type)
      warnings << "Target edge #{target_server.edge_type.inspect} has no adapter — run edge " \
                  "detection, or pick a Caddy/kamal-proxy box."
    end
    warnings << "App has no domain to repoint — add one on the target edge before cut-over." if app.domain.blank?
    warnings << "Dedicated replicate across differing Postgres majors uses dump/restore — verify client versions." if app.dedicated_db?
    warnings
  end

  def step(phase, action, detail) = { phase: phase, action: action, detail: detail }
end
