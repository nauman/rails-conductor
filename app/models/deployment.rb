class Deployment < ApplicationRecord
  STATUSES = %w[pending building deploying succeeded failed cancelled].freeze

  belongs_to :app
  belongs_to :server, optional: true
  belongs_to :user, optional: true

  validates :status, inclusion: { in: STATUSES }

  scope :recent, -> { order(created_at: :desc) }
  scope :successful, -> { where(status: "succeeded") }
  scope :failed, -> { where(status: "failed") }
  scope :in_progress, -> { where(status: %w[pending building deploying]) }

  # Live deploy status: push a Turbo Stream replace of the status badge whenever
  # the status changes (building → deploying → succeeded/failed), so the
  # deployment page updates without a reload. Subscribe with turbo_stream_from.
  after_update_commit :broadcast_status_badge, if: :saved_change_to_status?

  def broadcast_status_badge
    broadcast_replace_to self,
      target: ActionView::RecordIdentifier.dom_id(self, :status_badge),
      partial: "deployments/status_badge", locals: { deployment: self }
  end

  def pending?
    status == "pending"
  end

  def building?
    status == "building"
  end

  def deploying?
    status == "deploying"
  end

  def succeeded?
    status == "succeeded"
  end

  def failed?
    status == "failed"
  end

  def in_progress?
    %w[pending building deploying].include?(status)
  end

  def duration
    return nil unless started_at
    end_time = completed_at || Time.current
    (end_time - started_at).to_i
  end

  def formatted_duration
    return "—" unless duration
    if duration < 60
      "#{duration}s"
    else
      "#{duration / 60}m #{duration % 60}s"
    end
  end

  def append_log(message)
    timestamp = Time.current.strftime("%H:%M:%S")
    new_line = "[#{timestamp}] #{message}\n"
    update!(log: (log || "") + new_line)
  end

  def start!
    update!(status: "building", started_at: Time.current)
  end

  def mark_deploying!
    update!(status: "deploying")
  end

  def succeed!
    update!(status: "succeeded", completed_at: Time.current)
    app.update!(status: "running", deployed_at: Time.current)
  end

  def fail!(error_message = nil)
    append_log("ERROR: #{error_message}") if error_message
    update!(status: "failed", completed_at: Time.current)
    app.update!(status: "failed")

    # Send notification
    AlertMailer.deployment_failed(self).deliver_later
  end
end
