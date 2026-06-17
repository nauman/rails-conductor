class CreateMcpCalls < ActiveRecord::Migration[8.1]
  def change
    create_table :mcp_calls do |t|
      t.references :user, null: true, foreign_key: true
      t.string :tool_name, null: false
      t.jsonb :arguments, null: false, default: {}
      t.text :result
      t.text :error
      t.string :status, null: false, default: "success"
      t.integer :duration_ms
      t.timestamps
    end

    add_index :mcp_calls, :created_at
  end
end
