class BackupsController < ApplicationController
  include OperatorOnly
  owner_only :destroy, :destroy
  before_action :set_backup, only: [:show, :edit, :update, :destroy, :run]

  def index
    @backups = current_organization.backups.includes(:server, :app, :credential).order(created_at: :desc)
    # Coverage leads the page: the fleet had 0 of 12 apps protected and the old list
    # couldn't show that, because an app with no backup has no row.
    @unprotected_apps = current_organization.apps.naggable.includes(:backups).reject { |app| app.backups.any? }
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

  # Protect every app that should be protected, with defaults the operator can change
  # afterwards. Skips apps that already have a backup, and apps the operator has parked —
  # acting on a placeholder is the same mistake as nagging about one.
  def protect_all
    protected_now = current_organization.apps.naggable.reject { |app| app.backups.any? }
                                        .filter_map { |app| BackupDefaults.new(app).protect! }

    notice = if protected_now.any?
      "Protected #{helpers.pluralize(protected_now.size, 'app')} — nightly, keep 14 days. Change any of it below."
    else
      "Nothing to protect: every app that should have a backup already has one."
    end

    redirect_to backups_path, notice: notice
  end

  def run
    run = @backup.record_dispatch!(trigger: "manual")
    BackupJob.perform_later(@backup.id, run.id)
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
