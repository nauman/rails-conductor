# A single app transfer (or clone) between two servers — the persisted state of
# the spec-26 Part 3 pipeline. AppTransferRunner drives it through the phases and
# records progress here so a crashed run is visible and rollback-able.
class AppTransfer < ApplicationRecord
  # transfer = full move (cut over + drain the source). clone = cut over but keep
  # the source live. stage = copy + deploy + publish and STOP before cut-over, so
  # the target can be verified before any DNS change (source stays fully live).
  MODES    = %w[transfer clone stage].freeze
  STATUSES = %w[pending running succeeded failed].freeze
  # The ordered pipeline. `database` (provision the target DB + replicate data)
  # runs BEFORE `compute` (deploy to the target) so the app boots against a
  # populated DB — deploying first would run migrations on an empty DB and the
  # later restore would collide with that schema. A clone stops before `drain`,
  # keeping the source live.
  PHASES   = %w[database compute edge cutover drain].freeze

  belongs_to :app
  belongs_to :organization
  belongs_to :source_server, class_name: "Server", optional: true
  belongs_to :target_server, class_name: "Server"

  validates :mode, inclusion: { in: MODES }
  validates :status, inclusion: { in: STATUSES }
  validate :distinct_servers
  validate :same_organization

  scope :recent, -> { order(created_at: :desc) }
  scope :in_progress, -> { where(status: %w[pending running]) }

  def clone?     = mode == "clone"
  def transfer?  = mode == "transfer"
  def stage?     = mode == "stage"
  def running?   = status == "running"
  def succeeded? = status == "succeeded"
  def failed?    = status == "failed"
  def done?      = succeeded? || failed?

  # The phases this run executes:
  #   stage    → database, compute, edge          (stop before DNS; verify first)
  #   clone    → database, compute, edge, cutover  (cut over, source stays live)
  #   transfer → all five                          (cut over, then drain source)
  def planned_phases
    case mode
    when "stage" then PHASES - %w[cutover drain]
    when "clone" then PHASES - %w[drain]
    else PHASES
    end
  end

  def append_log(line)
    self.log = "#{log}#{line}\n"
    update_columns(log: log, updated_at: Time.current)
  end

  private

  def distinct_servers
    return if source_server_id.blank?

    errors.add(:target_server, "must differ from the source server") if source_server_id == target_server_id
  end

  # A transfer never crosses an org: the app, both servers, and this record all
  # belong to one organization. AppTransferOrgBoundary enforces the same rule in
  # the plan and the runner; this stops a bad record from being persisted at all.
  def same_organization
    return if organization_id.blank?

    errors.add(:app, "belongs to another organization") if app && app.organization_id != organization_id
    [ :source_server, :target_server ].each do |role|
      server = public_send(role)
      next if server.nil? || server.organization_id == organization_id

      errors.add(role, "belongs to another organization")
    end
  end
end
