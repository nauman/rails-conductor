class AddObjectKeyToBackupRuns < ActiveRecord::Migration[8.1]
  def change
    # Which object this run actually uploaded. Without it, "verify the backup"
    # has to guess by listing the bucket and hoping the newest key is the one
    # that run produced — which is exactly the kind of inference that turns into
    # a false result.
    add_column :backup_runs, :object_key, :string
  end
end
