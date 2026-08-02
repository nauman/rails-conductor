class AddReleaseDriftToApps < ActiveRecord::Migration[8.1]
  def change
    # Stored rollup, same shape as residue_findings/residue_checked_at: the job
    # pays the SSH cost, request paths read what was stored.
    add_column :apps, :release_state, :jsonb, default: {}, null: false
    add_column :apps, :release_checked_at, :datetime
  end
end
