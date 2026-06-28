class AddUniqueActiveDeployIndexToDeployments < ActiveRecord::Migration[8.1]
  # Enforce "at most one in-flight deployment per app" as a DB invariant, so
  # concurrent triggers (MCP + chat + UI button) can't both start a kamal deploy
  # and collide on the per-service lock. The 2nd concurrent create! now raises
  # RecordNotUnique; App#start_deployment! rescues it and returns the existing one.
  def up
    # Resolve any pre-existing duplicate active deployments (keep the newest per
    # app) so the unique index applies cleanly.
    execute(<<~SQL)
      UPDATE deployments SET status = 'cancelled'
      WHERE id IN (
        SELECT id FROM (
          SELECT id, ROW_NUMBER() OVER (PARTITION BY app_id ORDER BY created_at DESC) AS rn
          FROM deployments
          WHERE status IN ('pending', 'building', 'deploying')
        ) ranked
        WHERE ranked.rn > 1
      )
    SQL

    add_index :deployments, :app_id, unique: true,
      where: "status IN ('pending', 'building', 'deploying')",
      name: "idx_one_active_deploy_per_app"
  end

  def down
    remove_index :deployments, name: "idx_one_active_deploy_per_app"
  end
end
