class Script < ApplicationRecord
  TYPES = %w[provision deploy setup maintenance].freeze

  belongs_to :organization, optional: true # nil = global built-in (admin-owned)
  has_many :script_runs, dependent: :nullify

  validates :name, presence: true, uniqueness: { scope: :organization_id }
  validates :body, presence: true
  validates :script_type, inclusion: { in: TYPES }

  # Scripts an org may see and run: global built-ins + the org's own.
  scope :visible_to, ->(org) { where(organization_id: [ nil, org&.id ].uniq) }

  # A global/built-in script is platform-admin-only; an org script is editable by
  # an operator (owner/admin) of the owning org. Never editable across tenants.
  def editable_by?(user, organization)
    return false if user.nil?
    return user.admin? if built_in? || organization_id.nil?

    organization_id == organization&.id && OperatorPolicy.operator?(user, organization)
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
