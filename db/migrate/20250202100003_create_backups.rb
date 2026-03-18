class CreateBackups < ActiveRecord::Migration[8.0]
  def change
    create_table :backups do |t|
      t.references :server, foreign_key: true
      t.references :app, foreign_key: true
      t.string :provider, null: false
      t.string :bucket_name, null: false
      t.bigint :size_bytes, default: 0
      t.string :status, default: "pending"
      t.integer :retention_days, default: 7
      t.datetime :completed_at

      t.timestamps
    end

    add_index :backups, :status
    add_index :backups, :provider
  end
end
