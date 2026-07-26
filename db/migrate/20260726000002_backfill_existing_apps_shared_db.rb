# Audit fix (spec 26): the placement-axes migration defaulted the columns to
# dedicated+colocated for NEW apps, but that default also backfilled every
# EXISTING app — which actually runs on a shared cluster. Reclassify all apps
# that exist at migration time as shared/colocated, so transfer planning and the
# provisioner don't treat an existing shared database as a dedicated container.
#
# Safe to backfill unconditionally: the dedicated-container path is not wired
# yet, so no existing app has a real <app>-db container to preserve. New apps
# created after this migration keep the column default (`dedicated`+`colocated`).
class BackfillExistingAppsSharedDb < ActiveRecord::Migration[8.1]
  def up
    execute("UPDATE apps SET database_mode = 'shared', database_placement = 'colocated'")
  end

  def down
    # No-op: backfilled rows are indistinguishable from intentional shared apps.
  end
end
