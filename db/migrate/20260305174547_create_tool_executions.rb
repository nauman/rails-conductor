class CreateToolExecutions < ActiveRecord::Migration[8.1]
  def change
    create_table :tool_executions do |t|
      t.bigint :message_id, null: false
      t.string :tool_name, null: false
      t.jsonb :tool_input, null: false, default: {}
      t.jsonb :tool_output
      t.string :status, null: false, default: 'pending'
      t.datetime :started_at
      t.datetime :completed_at

      t.timestamps
    end

    add_index :tool_executions, :message_id
    add_index :tool_executions, :tool_name
    add_index :tool_executions, :status
    add_foreign_key :tool_executions, :messages
  end
end
