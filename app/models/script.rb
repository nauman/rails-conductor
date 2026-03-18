class Script < ApplicationRecord
  TYPES = %w[provision deploy setup].freeze

  has_many :script_runs, dependent: :nullify

  validates :name, presence: true, uniqueness: true
  validates :body, presence: true
  validates :script_type, inclusion: { in: TYPES }

  scope :provision, -> { where(script_type: 'provision') }
  scope :deploy,    -> { where(script_type: 'deploy') }
  scope :setup,     -> { where(script_type: 'setup') }
  scope :built_in,  -> { where(built_in: true) }

  def provision? = script_type == 'provision'
  def deploy?    = script_type == 'deploy'
  def setup?     = script_type == 'setup'
end
