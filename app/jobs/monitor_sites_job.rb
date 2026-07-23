# Recurring: ping every app with a public URL, record a SiteCheck, and keep the
# series bounded. Lean uptime/latency monitoring — the automated diagnosis.
class MonitorSitesJob < ApplicationJob
  queue_as :ops

  RETAIN = 7.days

  def perform
    App.where.not(domain: [ nil, "" ]).find_each do |app|
      next unless app.monitorable?

      SiteMonitor.new(app).check!
    rescue => e
      Rails.logger.warn("[monitor_sites] #{app.name}: #{e.message}")
    end

    # Bound the table: drop samples older than the retention window.
    SiteCheck.where("checked_at < ?", RETAIN.ago).delete_all
  end
end
