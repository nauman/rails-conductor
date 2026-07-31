# A rollback target is only valid for the FORM the app was in when it shipped.
#
# `Deployment.rollbackable` meant "any successful deploy with a version", so a
# Kamal-era release (or a CI-reported one) could be offered as a rollback target
# for an app now on docker — where that tag names no local image — and could
# consume the docker app's five retention slots, evicting genuinely usable ones.
#
# Recording the runtime and infra revision each deployment shipped under makes
# "valid target for the app as it is now" answerable.
# APPLIED IN PRODUCTION AS WRITTEN — do not edit.
#
# Its backfill stamps every historical row with the app's CURRENT form, which
# invents exactly the distinction the column exists to make. That was corrected
# by 20260801000001 rather than by changing this file: editing an applied
# migration changes nothing in any database that already ran it, and leaves the
# repo describing something that never happened.
class AddRuntimeToDeployments < ActiveRecord::Migration[8.0]
  def up
    add_column :deployments, :deploy_method, :string
    add_column :deployments, :infra_revision, :integer

    # Backfill from the app's CURRENT form. Imperfect for apps that have changed
    # form — but strictly better than nil, which no scope can reason about, and
    # the alternative is inventing history we do not have.
    execute(<<~SQL)
      UPDATE deployments d
      SET deploy_method = a.deploy_method,
          infra_revision = a.infra_revision
      FROM apps a
      WHERE d.app_id = a.id AND d.deploy_method IS NULL
    SQL

    add_index :deployments, [ :app_id, :deploy_method, :status ]
  end

  def down
    remove_index :deployments, [ :app_id, :deploy_method, :status ]
    remove_column :deployments, :deploy_method
    remove_column :deployments, :infra_revision
  end
end
