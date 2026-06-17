class AppsController < ApplicationController
  before_action :set_app, only: [:show, :edit, :update, :destroy, :deploy, :stop, :restart, :logs, :env_vars, :sync_status, :provision_database]

  def index
    @apps = current_organization.apps.includes(:server).order(created_at: :desc)
  end

  def show
    @deployments = @app.deployments.recent.limit(10)
    @env_variables = @app.env_variables.order(:key)
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

    if @app.deployments.in_progress.any?
      return redirect_to @app, alert: "A deployment is already in progress."
    end

    deployment = @app.deployments.create!(user: current_user)
    DeployAppJob.perform_later(deployment.id)

    redirect_to @app, notice: "Deployment started. Check logs for progress."
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
    RestartAppJob.perform_later(@app.id)
    redirect_back fallback_location: @app, notice: "Restart initiated. Status will update shortly."
  end

  def logs
    if @app.server.present? && @app.server.ssh_configured?
      ssh = SshConnection.new(@app.server)
      command = if @app.native?
        "journalctl --user -u #{@app.service_name} -n 100 --no-pager"
      else
        "docker logs --tail 100 #{@app.container_name}"
      end
      ssh.execute(command)
      @logs = ssh.output || ssh.error
    else
      @logs = "No server configured or SSH not available for this app."
    end

    respond_to do |format|
      format.html
      format.json { render json: { logs: @logs, updated_at: Time.current.iso8601 } }
    end
  end

  def sync_status
    SyncContainerStatusJob.perform_later(@app.id)
    redirect_back fallback_location: @app, notice: "Status sync initiated."
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
      :health_check_path, :ssl_enabled, :deploy_method, :notes
    )
  end
end
