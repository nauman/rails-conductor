require "shellwords"

class ServersController < ApplicationController
  include OperatorOnly
  before_action :set_server, only: [ :show, :edit, :update, :destroy, :test_connection, :refresh_metrics, :provision, :logs, :health, :install_packages, :audit, :apply_updates, :sudo_check, :reboot ]

  def index
    @servers = current_organization.servers.includes(:ssh_key, :apps).order(created_at: :desc)
    @online_count = @servers.count { |s| s.display_status == "online" }
    @app_count = @servers.sum { |s| s.apps.size }
    @running_app_count = @servers.sum { |s| s.apps.count { |a| a.status == "running" } }
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
      # Refresh metrics so a successful test also updates last_seen_at — otherwise
      # the server keeps displaying "pending" despite a working connection.
      ServerMetrics.new(@server).fetch_and_update!
      EdgeDetector.new(@server).detect_and_update! # best-effort: record the web edge
      redirect_to @server, notice: "SSH connection successful!"
    else
      redirect_to @server, alert: "SSH connection failed: #{ssh.error}"
    end
  end

  def refresh_metrics
    metrics_service = ServerMetrics.new(@server)

    if metrics_service.fetch_and_update!
      EdgeDetector.new(@server).detect_and_update! # keep the edge fresh too
      redirect_to @server, notice: "Metrics refreshed successfully."
    else
      redirect_to @server, alert: "Failed to refresh metrics: #{metrics_service.error}"
    end
  end

  # Deep health check (disk/memory/load/swap/failed-units/reboot) over SSH.
  # Rendered into a lazy turbo-frame on the server page + JSON for refresh.
  def health
    @health = ServerHealth.new(@server).check

    respond_to do |format|
      format.html { render partial: "servers/health", locals: { server: @server, health: @health } }
      format.json do
        render json: {
          status: @health.status,
          error:  @health.error,
          checks: @health.checks.map { |c| { key: c.key, label: c.label, status: c.status, detail: c.detail } }
        }
      end
    end
  end

  def storage
    @storage = ServerStorage.new(@server).load

    respond_to do |format|
      format.html { render partial: "servers/storage", locals: { server: @server, storage: @storage } }
      format.json do
        render json: {
          error:    @storage.error,
          mounts:   @storage.mounts.map(&:to_h),
          swap:     @storage.swap,
          memory:   @storage.memory,
          top_dirs: @storage.top_dirs.map(&:to_h)
        }
      end
    end
  end

  # Read-only security + patch-posture audit (firewall, SSH hardening, pending
  # security updates, DB exposure…) over SSH. Lazy turbo-frame panel + JSON.
  def audit
    @audit = ServerAudit.new(@server).audit
    # Persist the rollup so the deploy preflight can read posture without re-probing.
    @server.record_audit!(@audit.status) if @audit.ok?

    respond_to do |format|
      format.html { render partial: "servers/audit", locals: { server: @server, audit: @audit } }
      format.json do
        render json: {
          status: @audit.status, error: @audit.error,
          checks: @audit.checks.map { |c| { key: c.key, label: c.label, status: c.status, detail: c.detail } }
        }
      end
    end
  end

  # Install apt packages on this server (async — apt can be slow). Validation +
  # the actual sudo apt-get run live in PackageInstaller; here we just mark the
  # run "running" (drives the reactive panel) and enqueue it.
  def install_packages
    packages = PackageInstaller.parse_list(params[:packages])
    if packages.empty?
      return redirect_to @server, alert: "Enter one or more package names to install."
    end

    @server.update!(
      last_package_install_status:   "running",
      last_package_install_packages: packages.join(" ").first(255),
      last_package_install_log:      nil,
      last_package_install_at:       Time.current
    )
    InstallPackagesJob.perform_later(@server.id, packages)
    redirect_to @server, notice: "Installing #{packages.join(', ')}… the result will appear below."
  end

  # Apply OS updates (async). scope=security (default, safe) or all (may restart
  # docker/kernel and briefly bounce apps — the UI confirms that first).
  def apply_updates
    scope = params[:scope] == "all" ? "all" : "security"
    @server.update!(last_update_status: "running", last_update_scope: scope,
                    last_update_log: nil, last_update_at: Time.current)
    ApplyUpdatesJob.perform_later(@server.id, scope)
    redirect_to @server, notice: "Applying #{scope} updates on #{@server.name}… the result will appear below."
  end

  # Passwordless-sudo readiness ("Prepare server"): privileged ops (updates, reboot)
  # need a NOPASSWD grant. Show whether it's set + the one-time command to set it.
  def sudo_check
    @ready = ServerSudo.ready?(SshConnection.new(@server)) if @server.ssh_configured?
    @grant_command = ServerSudo.grant_command(@server)
    render partial: "servers/sudo_check", locals: { server: @server, ready: @ready, grant_command: @grant_command }
  end

  def reboot
    result = ServerReboot.new(@server).reboot!
    if result.success?
      redirect_to @server, notice: result.message
    else
      redirect_to @server, alert: result.message
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
    script = Script.visible_to(current_organization).find(params[:script_id])
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
