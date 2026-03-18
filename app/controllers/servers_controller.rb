class ServersController < ApplicationController
  before_action :set_server, only: [:show, :edit, :update, :destroy, :test_connection, :refresh_metrics, :provision]

  def index
    @servers = Server.includes(:ssh_key).order(created_at: :desc)
  end

  def show
  end

  def new
    @server = Server.new
  end

  def edit
  end

  def create
    @server = Server.new(server_params)

    if @server.save
      redirect_to @server, notice: "Server created successfully."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def update
    if @server.update(server_params)
      redirect_to @server, notice: "Server updated successfully."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @server.destroy
    redirect_to servers_path, notice: "Server deleted."
  end

  def test_connection
    ssh = SshConnection.new(@server)

    if ssh.test
      redirect_to @server, notice: "SSH connection successful!"
    else
      redirect_to @server, alert: "SSH connection failed: #{ssh.error}"
    end
  end

  def refresh_metrics
    metrics_service = ServerMetrics.new(@server)

    if metrics_service.fetch_and_update!
      redirect_to @server, notice: "Metrics refreshed successfully."
    else
      redirect_to @server, alert: "Failed to refresh metrics: #{metrics_service.error}"
    end
  end

  def provision
    script = Script.find(params[:script_id])
    run = ScriptRun.create!(
      server: @server,
      script: script,
      user: current_user
    )
    ScriptRunJob.perform_later(run.id)
    redirect_to script_run_path(run), notice: "Script started — streaming output below."
  rescue ActiveRecord::RecordNotFound
    redirect_to @server, alert: "Script not found."
  end

  private

  def set_server
    @server = Server.find(params[:id])
  end

  def server_params
    params.require(:server).permit(
      :name, :ip_address, :provider, :region, :status,
      :cpu_percent, :memory_used_mb, :memory_total_mb, :disk_percent,
      :ssh_key_id, :ssh_user, :ssh_port
    )
  end
end
