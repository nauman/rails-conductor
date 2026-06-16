class CreateDatabaseClustersAndDatabases < ActiveRecord::Migration[8.1]
  def change
    create_table :database_clusters do |t|
      t.references :organization, null: false, foreign_key: true
      t.references :server, null: false, foreign_key: true
      t.string :name, null: false
      t.string :container_name, null: false
      t.string :admin_username, null: false
      t.text :admin_password
      t.integer :port, default: 5432
      t.timestamps
    end

    create_table :databases do |t|
      t.references :organization, null: false, foreign_key: true
      t.references :database_cluster, null: false, foreign_key: true
      t.references :app, null: true, foreign_key: true
      t.string :name, null: false
      t.string :username, null: false
      t.text :password
      t.string :status, null: false, default: "pending"
      t.timestamps
    end
  end
end
