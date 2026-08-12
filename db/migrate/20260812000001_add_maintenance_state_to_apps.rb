class AddMaintenanceStateToApps < ActiveRecord::Migration[8.1]
  def change
    add_column :apps, :maintenance_mode, :boolean, null: false, default: false
    add_column :apps, :maintenance_message, :string
  end
end
