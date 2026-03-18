class AddMissingColumnsToServers < ActiveRecord::Migration[8.1]
  def change
    change_table :servers do |t|
      t.string :ip_address unless column_exists?(:servers, :ip_address)
      t.string :provider unless column_exists?(:servers, :provider)
      t.string :region unless column_exists?(:servers, :region)
      t.integer :cpu_percent, default: 0 unless column_exists?(:servers, :cpu_percent)
      t.integer :memory_used_mb, default: 0 unless column_exists?(:servers, :memory_used_mb)
      t.integer :memory_total_mb, default: 0 unless column_exists?(:servers, :memory_total_mb)
      t.integer :disk_percent, default: 0 unless column_exists?(:servers, :disk_percent)
      t.datetime :last_seen_at unless column_exists?(:servers, :last_seen_at)
      t.string :agent_url unless column_exists?(:servers, :agent_url)
      t.string :agent_token unless column_exists?(:servers, :agent_token)
    end
  end
end
