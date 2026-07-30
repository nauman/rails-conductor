# Decommission (retire) is a first-class app-lifecycle stage that MIRRORS
# AppTransfer: the persisted state of retiring an app FROM a box. The runner
# drives it through the phases (containers → dedicated_db → records) and records
# progress + the discovery report here so a crashed run is visible and the audit
# trail survives. `findings` is the discovery-first report (JSON); `log` is the
# action-by-action audit trail; `dry_run` marks a report-only (bare-call) record.
class CreateDecommissions < ActiveRecord::Migration[8.1]
  def change
    create_table :decommissions do |t|
      t.references :app, null: false, foreign_key: true
      t.references :organization, null: false, foreign_key: true
      t.references :server, null: false, foreign_key: true
      t.string :status, null: false, default: "pending"
      t.string :phase
      t.text :findings
      t.text :log
      t.datetime :started_at
      t.datetime :finished_at
      t.boolean :dry_run, null: false, default: false
      t.timestamps
    end

    add_index :decommissions, [ :app_id, :created_at ]
    add_index :decommissions, :status
  end
end
