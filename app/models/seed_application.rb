# One recorded run of an app's db/seeds.rb — the ledger behind the deploy
# preflight's "seeds applied?" check. Migrations are gated in the deploy path;
# seeds have no such gate, so this makes their state auditable instead of a guess.
class SeedApplication < ApplicationRecord
  belongs_to :app

  scope :succeeded, -> { where(status: "succeeded") }

  def succeeded? = status == "succeeded"
end
