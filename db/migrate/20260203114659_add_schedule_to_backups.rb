class AddScheduleToBackups < ActiveRecord::Migration[8.1]
  def change
    add_column :backups, :schedule, :string, default: "daily"
    add_column :backups, :enabled, :boolean, default: false
    add_column :backups, :last_run_at, :datetime
    add_column :backups, :next_run_at, :datetime

    add_index :backups, [:enabled, :next_run_at]
  end
end
