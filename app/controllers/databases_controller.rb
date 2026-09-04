class DatabasesController < ApplicationController
  include OperatorOnly
  # destroy drops the live database AND its role — not recoverable.
  owner_only :destroy, :destroy
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
      # KEEP THE RECORD. Destroying it after a failed drop leaves a live database
      # nothing tracks — it stops appearing in Conductor, keeps its disk and its
      # credentials, and the next provision under the same name fails for a reason
      # no longer visible anywhere.
      return redirect_to cluster,
                         alert: "Kept the record — the cluster refused to drop it: #{e.message}"
    end

    database.destroy
    redirect_to cluster, notice: "Database '#{database.name}' removed."
  end

  private

  def database_params
    params.require(:database).permit(:name, :username, :app_id)
  end
end
