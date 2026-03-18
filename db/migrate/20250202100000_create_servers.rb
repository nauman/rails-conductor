class CreateServers < ActiveRecord::Migration[8.0]
  def change
    create_table :servers do |t|
      t.string :name, null: false
      t.string :ip_address
      t.string :provider
      t.string :region
      t.string :status, default: "offline"
      t.integer :cpu_percent, default: 0
      t.integer :memory_used_mb, default: 0
      t.integer :memory_total_mb, default: 0
      t.integer :disk_percent, default: 0
      t.datetime :last_seen_at
      t.string :agent_url
      t.string :agent_token

      t.timestamps
    end

    add_index :servers, :name, unique: true
    add_index :servers, :status
  end
end
