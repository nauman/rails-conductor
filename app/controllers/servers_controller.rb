require "shellwords"

class ServersController < ApplicationController
  before_action :set_server, only: [:show, :edit, :update, :destroy, :test_connection, :refresh_metrics, :provision, :logs]

  def index
    @servers = current_organization.servers.includes(:ssh_key).order(created_at: :desc)
  end

  def show
  end

  def new
    @server = current_organization.servers.new
  end

  def edit
  end

  def create
    @server = current_organization.servers.new(server_params)

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

  # Live tail of the host's logs over SSH. Defaults to the systemd journal
  # ("server log"); pass ?container=<name> to tail a specific docker container
  # (e.g. Conductor's own container, or any app on the box). Mirrors the app
  # log tail (auto-refreshing JSON), so the same UI works server-wide.
  def logs
    @tail = [ (params[:tail] || 300).to_i, 2000 ].min
    @container = params[:container].presence
    @containers = @server.apps.where.not(container_status: [ nil, "" ]).order(:name)

    if @server.ssh_configured?
      ssh = SshConnection.new(@server)
      ssh.execute(log_command(@container, @tail))
      @logs = ssh.output.presence || ssh.error
    else
      @logs = "SSH not configured for this server."
    end

    respond_to do |format|
      format.html
      format.json { render json: { logs: @logs, updated_at: Time.current.iso8601 } }
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

  # System journal by default; a specific container's docker logs when chosen.
  # Container name is shell-escaped; tail is integer-coerced above.
  def log_command(container, tail)
    if container
      "docker logs --tail #{tail} #{Shellwords.escape(container)} 2>&1"
    else
      "journalctl -n #{tail} --no-pager 2>&1 || sudo -n journalctl -n #{tail} --no-pager 2>&1"
    end
  end

  def set_server
    @server = current_organization.servers.find(params[:id])
  end

  def server_params
    params.require(:server).permit(
      :name, :ip_address, :provider, :region, :status,
      :cpu_percent, :memory_used_mb, :memory_total_mb, :disk_percent,
      :ssh_key_id, :ssh_user, :ssh_port
    )
  end
end
