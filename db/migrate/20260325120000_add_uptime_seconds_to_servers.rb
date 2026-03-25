class AddUptimeSecondsToServers < ActiveRecord::Migration[8.1]
  def change
    add_column :servers, :uptime_seconds, :integer, default: 0, null: false
  end
end
