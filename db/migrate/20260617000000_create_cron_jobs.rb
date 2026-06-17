class CreateCronJobs < ActiveRecord::Migration[8.1]
  def change
    create_table :cron_jobs do |t|
      t.references :organization, null: false, foreign_key: true
      t.references :server, null: false, foreign_key: true
      t.string :name, null: false
      t.text :command, null: false
      t.string :schedule, null: false
      t.string :cron_expression, null: false
      t.string :status, null: false, default: "enabled"
      t.timestamps
    end
  end
end
