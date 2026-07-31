# Stored rollup for residue detection, mirroring how server audits already work
# (`last_audit_at` / `last_audit_status`).
#
# ResidueDetector makes several SSH round-trips, so it cannot run on a page
# render or inline in a deploy — tried that, and it hung the app detail page and
# would have stalled deploys on an unreachable box. A job writes here; the fast
# paths read what was written.
class AddResidueRollupToApps < ActiveRecord::Migration[8.0]
  def change
    add_column :apps, :residue_checked_at, :datetime
    add_column :apps, :residue_findings, :jsonb, default: [], null: false
  end
end
