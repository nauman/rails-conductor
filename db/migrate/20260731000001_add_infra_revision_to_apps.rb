# ADR 0004 — identity is assigned, never derived.
#
# `infra_revision` versions an app's INFRASTRUCTURE SHAPE, separately from its
# code. It increments only when the app changes form (server, deploy method,
# edge, database shape) — never on an ordinary deploy, which is what
# `deployments.commit_sha` already records.
#
# Existing rows start at 1: whatever shape they are in now is revision 1, and
# the first form change after this migration makes it 2. `infra_revisions`
# carries the history so "what shapes has this app been in" is answerable.
class AddInfraRevisionToApps < ActiveRecord::Migration[8.0]
  def change
    add_column :apps, :infra_revision, :integer, default: 1, null: false

    create_table :infra_revisions do |t|
      t.references :app, null: false, foreign_key: true
      t.integer :revision, null: false
      # What changed, as { "server_id" => [1, 2], "deploy_method" => ["kamal", "docker"] }
      t.jsonb :changes_made, null: false, default: {}
      t.string :reason
      t.references :user, foreign_key: true # nil for system-initiated changes
      t.timestamps
    end

    add_index :infra_revisions, [ :app_id, :revision ], unique: true
  end
end
