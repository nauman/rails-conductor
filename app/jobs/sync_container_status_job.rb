class SyncContainerStatusJob < ApplicationJob
  queue_as :default

  def perform(app_id = nil)
    if app_id
      sync_single_app(app_id)
    else
      sync_all_apps
    end
  end

  private

  def sync_single_app(app_id)
    app = App.find_by(id: app_id)
    return unless app&.can_sync_status?

    service = ContainerStatus.new(app)
    unless service.sync!
      Rails.logger.warn "Failed to sync container status for #{app.name}: #{service.error}"
    end
  end

  def sync_all_apps
    App.with_server_ssh.find_each do |app|
      SyncContainerStatusJob.perform_later(app.id)
    end
  end
end
