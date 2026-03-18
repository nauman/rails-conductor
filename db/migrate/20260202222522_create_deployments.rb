class CreateDeployments < ActiveRecord::Migration[8.1]
  def change
    create_table :deployments do |t|
      t.references :app, null: false, foreign_key: true
      t.references :user, foreign_key: true
      t.string :status, default: "pending", null: false
      t.string :commit_sha
      t.text :log
      t.datetime :started_at
      t.datetime :completed_at

      t.timestamps
    end

    add_index :deployments, [:app_id, :status]
    add_index :deployments, :created_at
  end
end
