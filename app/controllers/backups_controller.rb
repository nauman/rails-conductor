class BackupsController < ApplicationController
  before_action :set_backup, only: [:show, :edit, :update, :destroy, :run]

  def index
    @backups = current_organization.backups.includes(:server, :app, :credential).order(created_at: :desc)
  end

  def show
  end

  def new
    @backup = current_organization.backups.new
    load_form_data
  end

  def edit
    load_form_data
  end

  def create
    @backup = current_organization.backups.new(backup_params)

    if @backup.save
      redirect_to @backup, notice: "Backup configuration created."
    else
      load_form_data
      render :new, status: :unprocessable_entity
    end
  end

  def update
    if @backup.update(backup_params)
      redirect_to @backup, notice: "Backup configuration updated."
    else
      load_form_data
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @backup.destroy
    redirect_to backups_path, notice: "Backup deleted."
  end

  def run
    BackupJob.perform_later(@backup.id)
    redirect_to @backup, notice: "Backup started. Check back for status."
  end

  private

  def set_backup
    @backup = current_organization.backups.find(params[:id])
  end

  def load_form_data
    @servers = current_organization.servers.order(:name)
    @apps = current_organization.apps.order(:name)
    @credentials = current_organization.credentials.active.where(provider: %w[cloudflare aws]).order(:name)
  end

  def backup_params
    params.require(:backup).permit(
      :server_id, :app_id, :credential_id, :provider, :bucket_name,
      :retention_days, :status, :enabled, :schedule
    )
  end
end
