class Script < ApplicationRecord
  TYPES = %w[provision deploy setup maintenance].freeze

  belongs_to :organization, optional: true # nil allowed ONLY for built-ins (global)
  has_many :script_runs, dependent: :nullify

  validates :name, presence: true, uniqueness: { scope: :organization_id }
  validates :body, presence: true
  validates :script_type, inclusion: { in: TYPES }
  # Only built-ins may be global. A tenant script must name its owning org, or it
  # would be exposed to (and runnable by) every other tenant via visible_to.
  validates :organization, presence: true, unless: :built_in?

  # Scripts an org may see and run: global built-ins + the org's own. A
  # non-built-in row with a nil org is an orphan and is visible to NO ONE
  # (quarantined) — nil is global only when built_in is true.
  scope :visible_to, ->(org) {
    global = where(built_in: true, organization_id: nil)
    org ? global.or(where(organization_id: org.id)) : global
  }

  # A global/built-in script is platform-admin-only; an org script is editable by
  # an OWNER of the owning org. Never editable across tenants. Editing a script
  # body is authoring code that later runs as root over SSH, so it sits in the
  # :execute band with running one — an editor gets neither.
  def editable_by?(user, organization)
    return false if user.nil?
    return user.admin? if built_in? || organization_id.nil?

    organization_id == organization&.id && OperatorPolicy.can?(user, organization, :execute)
  end

  scope :provision, -> { where(script_type: 'provision') }
  scope :deploy,    -> { where(script_type: 'deploy') }
  scope :setup,       -> { where(script_type: 'setup') }
  scope :maintenance, -> { where(script_type: 'maintenance') }
  scope :built_in,    -> { where(built_in: true) }

  def provision?   = script_type == 'provision'
  def deploy?      = script_type == 'deploy'
  def setup?       = script_type == 'setup'
  def maintenance? = script_type == 'maintenance'
end
