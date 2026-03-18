class CreateScripts < ActiveRecord::Migration[8.1]
  def change
    create_table :scripts do |t|
      t.string :name, null: false
      t.text :description
      t.text :body, null: false
      t.string :script_type, null: false, default: 'provision'
      t.boolean :built_in, null: false, default: false
      t.timestamps
    end
    add_index :scripts, :name, unique: true
    add_index :scripts, :script_type
  end
end
