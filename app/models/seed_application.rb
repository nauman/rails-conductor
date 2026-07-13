# One recorded run of an app's db/seeds.rb — the ledger behind the deploy
# preflight's "seeds applied?" check. Migrations are gated in the deploy path;
# seeds have no such gate, so this makes their state auditable instead of a guess.
#
# Integrity: a row is only "proven" (and may make the preflight green) when it
# both succeeded AND carries evidence it actually ran (applied_at). A bare row
# defaults to "pending", never a free green.
class SeedApplication < ApplicationRecord
  STATUSES = %w[pending succeeded failed].freeze

  belongs_to :app

  validates :status, inclusion: { in: STATUSES }

  scope :succeeded, -> { where(status: "succeeded") }
  scope :proven, -> { where(status: "succeeded").where.not(applied_at: nil) }

  def succeeded? = status == "succeeded"

  # Only a succeeded run with evidence of when it ran counts as real.
  def proven? = succeeded? && applied_at.present?
end
