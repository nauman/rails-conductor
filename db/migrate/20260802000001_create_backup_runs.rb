class CreateBackupRuns < ActiveRecord::Migration[8.1]
  def change
    create_table :backup_runs do |t|
      t.references :backup, null: false, foreign_key: true
      t.string :status, null: false, default: "dispatched"
      t.string :trigger, null: false, default: "scheduled"
      t.datetime :dispatched_at, null: false
      t.datetime :started_at
      t.datetime :finished_at
      t.bigint :size_bytes
      t.string :error_message

      t.timestamps
    end

    # The history read: "show me this schedule's recent attempts".
    add_index :backup_runs, [ :backup_id, :dispatched_at ]
    # The lost-dispatch sweep: dispatched rows that never started.
    add_index :backup_runs, [ :status, :dispatched_at ]
  end
end
