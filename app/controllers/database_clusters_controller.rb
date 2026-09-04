class DatabaseClustersController < ApplicationController
  include OperatorOnly
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
    # `kind` is set here, not permitted from the form. Registering means the
    # container already existed and a human typed its name — the case whose name is
    # editable and must not be the hostname apps resolve (ADR 0011). Letting the
    # form supply it would let a caller claim "dedicated" for a container Conductor
    # never assigned, which is the inference this column exists to replace.
    @cluster = current_organization.database_clusters.new(cluster_params.merge(kind: "shared"))

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
