# A single app decommission (retire) — the persisted state of retiring an app
# FROM a box. Mirrors AppTransfer: DecommissionRunner drives it through the
# phases and records progress here so a crashed run is visible and auditable.
#
# Discovery-first by design: `findings` holds the DecommissionPlan report (what
# the box ACTUALLY looked like — the real state is rarely what we assumed), and
# `log` is the action-by-action audit trail of what was actually removed.
class Decommission < ApplicationRecord
  STATUSES = %w[pending running succeeded failed].freeze
  # The ordered teardown pipeline, run FROM the retiring box:
  #   containers   → stop + remove the app's own service-labeled containers
  #   dedicated_db → remove the app's dedicated DB container + volume (never a
  #                  shared cluster's DB)
  #   records      → clean the stale Conductor Database records for THIS box
  PHASES = %w[containers dedicated_db records].freeze

  belongs_to :app
  belongs_to :organization
  belongs_to :server

  validates :status, inclusion: { in: STATUSES }
  validate :same_organization

  scope :recent, -> { order(created_at: :desc) }
  scope :in_progress, -> { where(status: %w[pending running]) }

  def running?   = status == "running"
  def succeeded? = status == "succeeded"
  def failed?    = status == "failed"
  def done?      = succeeded? || failed?

  # The discovery report as a Hash (findings is stored as JSON text). Empty when
  # nothing has been recorded yet.
  def findings_data
    return {} if findings.blank?

    JSON.parse(findings)
  rescue JSON::ParserError
    {}
  end

  def append_log(line)
    self.log = "#{log}#{line}\n"
    update_columns(log: log, updated_at: Time.current)
  end

  private

  # A decommission never crosses an org: the app, the server, and this record all
  # belong to one organization. Mirrors AppTransfer#same_organization.
  def same_organization
    return if organization_id.blank?

    errors.add(:app, "belongs to another organization") if app && app.organization_id != organization_id
    errors.add(:server, "belongs to another organization") if server && server.organization_id != organization_id
  end
end
