class AddSeedOnNextDeployToApps < ActiveRecord::Migration[8.1]
  def change
    # One-shot request: when set, the next deploy runs db:seed after migrations and
    # records a SeedApplication (the ledger's writer), then clears the flag. This
    # gives the deploy-preflight "seeds" gate real evidence instead of a warning.
    add_column :apps, :seed_on_next_deploy, :boolean, default: false, null: false
  end
end
