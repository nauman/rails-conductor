class AppHealth
  include ActionView::Helpers::DateHelper

  attr_reader :app

  def initialize(app, now: Time.current)
    @app = app
    @now = now
  end

  def desired_state
    app.status == "stopped" ? "stopped" : "running"
  end

  def observed_state
    app.container_status
  end

  def monitoring_state
    return "unsupported" unless app.status_sync_supported?
    return "unavailable" unless app.server&.ssh_configured?
    return "failed" if app.status_check_error.present?
    return "never_checked" if app.last_status_check_at.blank?
    return "stale" unless app.last_status_check_at > 5.minutes.ago

    "fresh"
  end

  def monitoring_label
    case monitoring_state
    when "unsupported" then "Unsupported · not checked"
    when "unavailable" then "Unavailable · #{unavailable_reason}"
    when "failed" then "Sync failed · #{error_summary}"
    when "never_checked" then "Never checked"
    when "stale" then "Checked #{checked_ago} ago · stale"
    else "Checked #{checked_ago} ago"
    end
  end

  def summary_state
    return "unknown" unless monitoring_state == "fresh"
    return "running" if %w[running restarting].include?(observed_state)
    return "stopped" if %w[exited dead paused].include?(observed_state)

    "unknown"
  end

  def incident
    return stopped_incident if desired_state == "stopped"
    return nil if monitoring_state == "unsupported"
    return monitoring_incident unless monitoring_state == "fresh"

    running_incident
  end

  private

  attr_reader :now

  def stopped_incident
    return nil unless monitoring_state == "fresh"
    return nil unless %w[running restarting].include?(observed_state)

    incident_hash("warning", "Running unexpectedly", "app")
  end

  def running_incident
    case observed_state
    when "running", "restarting" then nil
    when "exited", "dead", "paused"
      incident_hash("critical", "Expected running, observed #{observed_state}", "logs")
    else
      incident_hash("warning", "Runtime not observed", "sync")
    end
  end

  def monitoring_incident
    message = case monitoring_state
    when "unavailable" then "Monitoring unavailable: #{unavailable_reason}"
    when "failed" then "Status check failed"
    when "never_checked" then "Container has never been checked"
    when "stale" then "Container status is stale"
    end

    incident_hash("warning", message, "sync")
  end

  def incident_hash(severity, message, action)
    { type: "app", severity: severity, resource: app, message: message, action: action }
  end

  def unavailable_reason
    app.server ? "SSH unavailable" : "no server"
  end

  def error_summary
    app.status_check_error.to_s.lines.first.to_s.strip.truncate(80)
  end

  def checked_ago
    distance_of_time_in_words(app.last_status_check_at, now)
  end
end
