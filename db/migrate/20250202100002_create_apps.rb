class CreateApps < ActiveRecord::Migration[8.0]
  def change
    create_table :apps do |t|
      t.string :name, null: false
      t.string :slug, null: false
      t.references :server, foreign_key: true
      t.string :container_id
      t.integer :port
      t.string :domain
      t.string :status, default: "stopped"

      t.timestamps
    end

    add_index :apps, :slug, unique: true
    add_index :apps, :status
  end
end
