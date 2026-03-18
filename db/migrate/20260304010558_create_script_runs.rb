class CreateScriptRuns < ActiveRecord::Migration[8.1]
  def change
    create_table :script_runs do |t|
      t.bigint :server_id, null: false
      t.bigint :script_id, null: false
      t.bigint :user_id
      t.string :status, null: false, default: 'pending'
      t.text :log
      t.datetime :started_at
      t.datetime :completed_at
      t.timestamps
    end
    add_index :script_runs, :server_id
    add_index :script_runs, :script_id
    add_index :script_runs, :status
    add_foreign_key :script_runs, :servers
    add_foreign_key :script_runs, :scripts
  end
end
