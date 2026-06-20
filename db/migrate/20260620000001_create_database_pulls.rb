class CreateDatabasePulls < ActiveRecord::Migration[8.1]
  def change
    create_table :database_pulls do |t|
      t.references :server, null: false, foreign_key: true
      t.references :app, foreign_key: true
      t.references :user, foreign_key: true
      t.references :organization, foreign_key: true

      # How to obtain the source DATABASE_URL on the remote box. When env_file is
      # set it is sourced before pg_dump (Hatchbox stores it in .asdf-vars); the
      # URL is read from the named variable (default DATABASE_URL).
      t.string  :source_env_file
      t.string  :source_database_url_var, default: "DATABASE_URL", null: false
      t.string  :source_database # informational label only

      # Optional local Postgres database to restore the dump into after download.
      t.string  :restore_target
      t.string  :local_dump_path

      t.bigint   :size_bytes, default: 0, null: false
      t.string   :status, default: "pending", null: false
      t.text     :log
      t.datetime :started_at
      t.datetime :completed_at

      t.timestamps
    end

    add_index :database_pulls, :status
    add_index :database_pulls, :created_at
  end
end
