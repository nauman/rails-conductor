class CreateConversations < ActiveRecord::Migration[8.1]
  def change
    create_table :conversations do |t|
      t.bigint :user_id, null: false
      t.string :title
      t.string :status, null: false, default: 'active'
      t.jsonb :context, null: false, default: {}

      t.timestamps
    end

    add_index :conversations, :user_id
    add_index :conversations, :status
    add_index :conversations, :created_at
    add_foreign_key :conversations, :users
  end
end
