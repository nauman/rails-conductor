class DatabasePullsController < ApplicationController
  before_action :set_pull, only: [:show]

  def index
    @pulls = scoped_pulls.recent.includes(:server, :app).limit(100)
  end

  def show
  end

  def new
    @pull = DatabasePull.new(server_id: params[:server_id], app_id: params[:app_id])
    @servers = current_organization.servers.with_ssh.order(:name)
  end

  def create
    server = current_organization.servers.with_ssh.find(pull_params[:server_id])
    @pull = DatabasePull.new(pull_params)
    @pull.server = server
    @pull.app = current_organization.apps.find_by(id: pull_params[:app_id]) if pull_params[:app_id].present?
    @pull.organization = current_organization
    @pull.user = current_user
    @pull.status = "pending"

    if @pull.save
      DatabasePullJob.perform_later(@pull.id)
      redirect_to @pull, notice: "Database pull started."
    else
      @servers = current_organization.servers.with_ssh.order(:name)
      render :new, status: :unprocessable_entity
    end
  rescue ActiveRecord::RecordNotFound
    redirect_to new_database_pull_path, alert: "Select a server with SSH access."
  end

  private

  def set_pull
    @pull = scoped_pulls.find(params[:id])
  end

  # Pulls reachable by the current org (scoped through its servers).
  def scoped_pulls
    DatabasePull.where(server_id: current_organization.servers.select(:id))
  end

  def pull_params
    params.require(:database_pull).permit(
      :server_id, :app_id, :source_env_file, :source_database_url_var,
      :source_database, :restore_target
    )
  end
end
