class DatabaseClustersController < ApplicationController
  before_action :set_cluster, only: [:show]

  def index
    @clusters = current_organization.database_clusters.includes(:server, :databases).order(:name)
  end

  def show
    @databases = @cluster.databases.includes(:app).order(:name)
  end

  def new
    @cluster = current_organization.database_clusters.new(port: 5432)
    @servers = current_organization.servers.order(:name)
  end

  def create
    @cluster = current_organization.database_clusters.new(cluster_params)

    if @cluster.save
      redirect_to @cluster, notice: "Database cluster registered."
    else
      @servers = current_organization.servers.order(:name)
      render :new, status: :unprocessable_entity
    end
  end

  private

  def set_cluster
    @cluster = current_organization.database_clusters.find(params[:id])
  end

  def cluster_params
    params.require(:database_cluster).permit(:server_id, :name, :container_name, :admin_username, :admin_password, :port)
  end
end
