class AddContainerStatusToApps < ActiveRecord::Migration[8.0]
  def change
    add_column :apps, :container_status, :string, default: "unknown"
    add_column :apps, :container_started_at, :datetime
    add_column :apps, :last_status_check_at, :datetime
    add_column :apps, :status_check_error, :string
    add_index :apps, :container_status
  end
end
