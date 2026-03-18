class CreateMessages < ActiveRecord::Migration[8.1]
  def change
    create_table :messages do |t|
      t.bigint :conversation_id, null: false
      t.string :role, null: false
      t.text :content
      t.string :status, null: false, default: 'pending'
      t.integer :sequence, null: false, default: 0

      t.timestamps
    end

    add_index :messages, :conversation_id
    add_index :messages, [ :conversation_id, :sequence ]
    add_foreign_key :messages, :conversations
  end
end
