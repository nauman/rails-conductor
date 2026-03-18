class FixDeploymentsTable < ActiveRecord::Migration[8.1]
  def change
    # Add missing columns that Deployment model needs
    unless column_exists?(:deployments, :app_id)
      add_reference :deployments, :app, foreign_key: true
    end

    unless column_exists?(:deployments, :started_at)
      add_column :deployments, :started_at, :datetime
    end

    unless column_exists?(:deployments, :completed_at)
      add_column :deployments, :completed_at, :datetime
    end

    unless column_exists?(:deployments, :commit_sha)
      add_column :deployments, :commit_sha, :string
    end

    # Make script_id and server_id nullable — deployments are app-level,
    # script-based runs use ScriptRun instead
    if column_exists?(:deployments, :script_id)
      change_column_null :deployments, :script_id, true
    end

    if column_exists?(:deployments, :server_id)
      change_column_null :deployments, :server_id, true
    end

    if column_exists?(:deployments, :user_id)
      change_column_null :deployments, :user_id, true
    end
  end
end
