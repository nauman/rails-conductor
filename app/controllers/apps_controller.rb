class AppsController < ApplicationController
  include OperatorOnly
  before_action :set_app, only: [ :show, :edit, :update, :destroy, :deploy, :stop, :restart, :logs, :jobs, :env_vars, :sync_status, :provision_database, :generate_deploy_key, :toggle_auto_deploy, :toggle_deploy_hold, :toggle_seed_on_next_deploy, :deploy_config, :toggle_self_describing ]

  def index
    @apps = current_organization.apps.includes(:server).order(created_at: :desc)
  end

  def show
    @deployments = @app.deployments.recent.limit(10)
    @env_variables = @app.env_variables.order(:key)
    @preflight = DeployPreflight.new(@app).check if @app.deployable?
  end

  def new
    @app = current_organization.apps.new
    @servers = current_organization.servers.with_ssh.order(:name)
  end

  def edit
    @servers = current_organization.servers.with_ssh.order(:name)
  end

  def create
    @app = current_organization.apps.new(app_params)

    if @app.save
      redirect_to @app, notice: "App created successfully."
    else
      @servers = current_organization.servers.with_ssh.order(:name)
      render :new, status: :unprocessable_entity
    end
  end

  def update
    if @app.update(app_params)
      redirect_to @app, notice: "App updated successfully."
    else
      @servers = current_organization.servers.with_ssh.order(:name)
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @app.destroy
    redirect_to apps_path, notice: "App deleted."
  end

  def deploy
    unless @app.deployable?
      return redirect_to @app, alert: "App is not deployable. Configure server and repository first."
    end

    # Explicit truthy only — ActiveModel's Boolean cast treats any non-false
    # string (e.g. "banana") as true, which would silently override a blocking
    # preflight. Force must be a deliberate true.
    force = %w[1 true t yes on].include?(params[:force].to_s.strip.downcase)
    _deployment, status, preflight = @app.start_deployment!(user: current_user, force: force)

    case status
    when :already_running
      redirect_to @app, alert: "A deployment is already in progress."
    when :blocked
      blockers = preflight.checks.select { |c| c.status == :fail }.map { |c| "#{c.label}: #{c.detail}" }
      redirect_to @app,
        alert: "Deploy blocked by preflight — #{blockers.join("; ")}. Resolve, or re-run with Force to override."
    else
      redirect_to @app, notice: "Deployment started. Check logs for progress."
    end
  end

  def toggle_auto_deploy
    @app.update!(auto_deploy: !@app.auto_deploy)
    state = @app.auto_deploy? ? "enabled" : "disabled"
    redirect_to @app, notice: "Auto-deploy on push #{state}."
  end

  # One-shot seed request: the next deploy runs db:seed + records a SeedApplication,
  # then clears the flag. Makes the preflight "seeds" gate real.
  def toggle_seed_on_next_deploy
    # Only KamalDeployer consumes this flag; docker/native deploys would succeed
    # without ever running seeds and leave the flag stuck. Don't offer a promise
    # we can't keep.
    unless @app.kamal?
      return redirect_to @app, alert: "Seed-on-next-deploy is only supported for Kamal deploys (this app uses #{@app.deploy_method})."
    end

    @app.update!(seed_on_next_deploy: !@app.seed_on_next_deploy)
    msg = @app.seed_on_next_deploy? ? "Seeds will run on the next deploy." : "Seed-on-next-deploy cleared."
    redirect_to @app, notice: msg
  end

  # Threads gate: set/clear the deploy hold the preflight blocks on. An operator
  # holds while a coordination thread is owed, then clears it to let deploys run.
  def toggle_deploy_hold
    if @app.deploy_hold?
      @app.update!(deploy_hold: false, deploy_hold_reason: nil)
      # Surface any deploys that were refused while held, so the intent isn't lost —
      # the operator can re-trigger the latest commit now that the hold is gone.
      blocked = @app.deployments.blocked.recent
      if blocked.any?
        sha = blocked.first.commit_sha.to_s.first(7).presence || "the latest commit"
        redirect_to @app, notice: "Deploy hold cleared. #{blocked.count} deploy(s) were blocked while held (latest: #{sha}). Click Deploy to ship."
      else
        redirect_to @app, notice: "Deploy hold cleared."
      end
    else
      @app.update!(deploy_hold: true, deploy_hold_reason: params[:reason].presence || "Held by operator")
      redirect_to @app, alert: "Deploys held. The preflight will block until this is cleared."
    end
  end

  # Self-describing deploy config (ADR 0001): the REAL config/deploy.production.yml
  # + git-safe .kamal/secrets.production, generated from this app's record so
  # `kamal console -d production` works from the repo. Read-only preview to copy
  # into the repo (Kamal only for now).
  def deploy_config
    unless @app.kamal?
      return redirect_to @app, alert: "Self-describing deploy config is Kamal-only for now (this app deploys via #{@app.deploy_method})."
    end
    @files = KamalConfig.new(@app).files

    respond_to do |format|
      format.html
      format.json { render json: { files: @files } }
    end
  end

  # Opt this app into ADR 0001: deploys write the generated overlay + secrets and
  # run `kamal deploy -d production`. Default off — flipping is per-app + reversible.
  def toggle_self_describing
    @app.update!(self_describing: !@app.self_describing)
    state = @app.self_describing? ? "enabled" : "disabled"
    redirect_to deploy_config_app_path(@app), notice: "Self-describing deploy #{state} for #{@app.name}."
  end

  def stop
    unless @app.server.present? && @app.server.ssh_configured?
      return redirect_to @app, alert: "No server configured or SSH not available."
    end

    ssh = SshConnection.new(@app.server)
    command = @app.native? ? "systemctl --user stop #{@app.service_name}" : "docker stop #{@app.container_name}"

    if ssh.execute(command)
      @app.update!(status: "stopped")
      redirect_to @app, notice: "App stopped."
    else
      redirect_to @app, alert: "Failed to stop app: #{ssh.error}"
    end
  end

  def restart
    unless @app.restart_supported?
      return redirect_to @app, alert: "Restart is unavailable because this app has no server with usable SSH."
    end

    RestartAppJob.perform_later(@app.id)
    redirect_back fallback_location: @app, notice: "Restart initiated. Status will update shortly."
  end

  def logs
    @tail = [ (params[:tail] || 300).to_i, 2000 ].min
    if @app.server.present? && @app.server.ssh_configured?
      ssh = SshConnection.new(@app.server)
      command = @app.log_tail_command(@tail)
      ssh.execute(command)
      @logs = ssh.output.presence || ssh.error
    else
      @logs = "No server configured or SSH not available for this app."
    end

    respond_to do |format|
      format.html
      format.json { render json: { logs: @logs, updated_at: Time.current.iso8601 } }
    end
  end

  # Solid Queue (Rails default Active Job) health for this app, read straight
  # from its queue DB. Serves a lazy turbo-frame badge (fleet rollup), a full
  # page (deep view + link to mission_control-jobs), and JSON (refresh).
  def jobs
    @stats = SolidQueueStats.for(@app)

    respond_to do |format|
      format.html do
        if turbo_frame_request_id == "app_jobs_#{@app.id}"
          render partial: "apps/jobs_badge", locals: { app: @app, stats: @stats }
        else
          render :jobs
        end
      end
      format.json do
        render json: @stats.to_h.merge(workers_alive: @stats.workers_alive, healthy: @stats.healthy?)
      end
    end
  end

  def sync_status
    SyncContainerStatusJob.perform_later(@app.id)
    redirect_back fallback_location: @app, notice: "Status sync initiated."
  end

  # Generate (or regenerate) a read-only deploy key for cloning a private repo.
  def generate_deploy_key
    DeployKey.generate_for(@app)
    install = GithubDeployKeyInstaller.install(@app)
    if install[:installed]
      redirect_to @app, notice: "Deploy key generated and auto-added to #{install[:repo]} via GitHub integration."
    else
      redirect_to @app, notice: "Deploy key generated. Add the public key to GitHub (#{install[:reason]})."
    end
  rescue DeployKeyGenerator::Error => e
    redirect_to @app, alert: "Could not generate deploy key: #{e.message}"
  end

  # Provision a Postgres database for this app on a registered cluster.
  def provision_database
    cluster = current_organization.database_clusters.find_by(server_id: @app.server_id) ||
              current_organization.database_clusters.first
    unless cluster
      return redirect_to @app, alert: "No database cluster registered. Add one under Databases first."
    end

    base = @app.database_base_name
    cluster.provision_database!(name: "#{base}_production", username: base, app: @app)
    redirect_to @app, notice: "Database provisioned for #{@app.name}."
  rescue PostgresClusterClient::Error, ActiveRecord::RecordInvalid => e
    redirect_to @app, alert: "Could not provision database: #{e.message}"
  end

  def sync_all
    SyncContainerStatusJob.perform_later
    redirect_back fallback_location: root_path, notice: "Syncing all container statuses..."
  end

  def env_vars
    @env_variables = @app.env_variables.order(:key)
  end

  private

  def set_app
    @app = current_organization.apps.find(params[:id])
  end

  def app_params
    params.require(:app).permit(
      :name, :slug, :server_id, :port, :domain, :status,
      :repository_url, :branch, :dockerfile_path, :image_name,
      :health_check_path, :ssl_enabled, :deploy_method, :notes, :self_managed
    )
  end
end
