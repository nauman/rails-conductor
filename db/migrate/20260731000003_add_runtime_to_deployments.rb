# A rollback target is only valid for the FORM the app was in when it shipped.
#
# `Deployment.rollbackable` meant "any successful deploy with a version", so a
# Kamal-era release (or a CI-reported one) could be offered as a rollback target
# for an app now on docker — where that tag names no local image — and could
# consume the docker app's five retention slots, evicting genuinely usable ones.
#
# Recording the runtime and infra revision each deployment shipped under makes
# "valid target for the app as it is now" answerable.
class AddRuntimeToDeployments < ActiveRecord::Migration[8.0]
  def up
    add_column :deployments, :deploy_method, :string
    add_column :deployments, :infra_revision, :integer

    # DELIBERATELY NOT BACKFILLED from the app's current form.
    #
    # Stamping every historical row with the app's CURRENT runtime destroys
    # exactly the distinction this column exists to make: for an app moved
    # kamal → docker, every Kamal-era release would be labelled "docker" and
    # would still be offered as a rollback target naming an image that does not
    # exist locally. NULL means "unknown runtime", and rollbackable_for excludes
    # it — a smaller, honest set beats a larger, wrong one.
    #
    # Reconstruct only where the evidence is unambiguous: an app that has never
    # changed form (single infra revision, no recorded deploy_method change) has
    # always been in its current form, so those rows can be stamped safely.
    say_with_time "stamping deployments for apps that have never changed form" do
      execute(<<~SQL)
        UPDATE deployments d
        SET deploy_method = a.deploy_method,
            infra_revision = a.infra_revision
        FROM apps a
        WHERE d.app_id = a.id
          AND d.deploy_method IS NULL
          AND a.infra_revision = 1
          AND NOT EXISTS (
            SELECT 1 FROM infra_revisions r
            WHERE r.app_id = a.id AND r.changes_made ? 'deploy_method'
          )
      SQL
    end

    add_index :deployments, [ :app_id, :deploy_method, :status ]
  end

  def down
    remove_index :deployments, [ :app_id, :deploy_method, :status ]
    remove_column :deployments, :deploy_method
    remove_column :deployments, :infra_revision
  end
end
