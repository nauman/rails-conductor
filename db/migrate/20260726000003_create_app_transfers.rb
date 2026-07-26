# App-transfer spec 26, Part 3 (Slice 6): a persisted record of an app transfer
# (or clone), so the staged pipeline has crash-visible progress and a rollback
# anchor — mirrors Deployment/DatabasePull.
class CreateAppTransfers < ActiveRecord::Migration[8.1]
  def change
    create_table :app_transfers do |t|
      t.references :app, null: false, foreign_key: true
      t.references :organization, null: false, foreign_key: true
      t.references :source_server, foreign_key: { to_table: :servers }
      t.references :target_server, null: false, foreign_key: { to_table: :servers }
      t.string :mode, null: false, default: "transfer"   # transfer | clone
      t.string :status, null: false, default: "pending"  # pending running succeeded failed
      t.string :phase                                     # current/last phase reached
      t.text   :log
      t.string :error
      t.datetime :started_at
      t.datetime :finished_at
      t.timestamps
    end

    add_index :app_transfers, [ :app_id, :created_at ]
    add_index :app_transfers, :status
  end
end
