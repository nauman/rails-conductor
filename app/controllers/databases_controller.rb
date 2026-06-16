class DatabasesController < ApplicationController
  # Provision a database (role + database + password) on a cluster.
  def create
    cluster = current_organization.database_clusters.find(params[:database_cluster_id])
    cluster.provision_database!(name: database_params[:name], username: database_params[:username].presence)
    redirect_to cluster, notice: "Database '#{database_params[:name]}' provisioned."
  rescue PostgresClusterClient::Error, ActiveRecord::RecordInvalid => e
    redirect_to cluster, alert: "Could not provision database: #{e.message}"
  end

  # Drop the database (and role) on the cluster, then remove the record.
  def destroy
    database = current_organization.databases.find(params[:id])
    cluster = database.database_cluster
    begin
      PostgresClusterClient.new(cluster).drop_database(name: database.name, username: database.username)
    rescue PostgresClusterClient::Error => e
      flash[:alert] = "Dropped the record, but the cluster reported: #{e.message}"
    end
    database.destroy
    redirect_to cluster, notice: flash[:alert] ? nil : "Database '#{database.name}' removed."
  end

  private

  def database_params
    params.require(:database).permit(:name, :username, :app_id)
  end
end
