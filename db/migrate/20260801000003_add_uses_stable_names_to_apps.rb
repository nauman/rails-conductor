# ADR 0004's alias period, made explicit.
#
# Native units (`<slug>-server`), dedicated DB containers (`<slug>-db`), volumes
# (`<slug>-db-data`) and checkout paths are all slug-derived, so a rename or a
# form change orphans them. The stable `app-<id>` key fixes that — but these name
# LIVE infrastructure, so flipping the derivation in code would orphan every
# existing resource in exactly the way this work exists to prevent.
#
# So the choice is recorded per app rather than decided globally:
#
#   false (default) — legacy slug-derived names. Every app that exists today,
#                     because its resources are already named that way and running.
#   true            — stable app-<id> names. Set for apps created from now on,
#                     which have nothing live to orphan.
#
# Lookups accept BOTH regardless, so Conductor can find a resource under either
# name for as long as the fleet is mixed. Migrating an existing app is an
# operator action (stop, rename, restart) and a form change — not a side effect
# of deploying new code.
class AddUsesStableNamesToApps < ActiveRecord::Migration[8.0]
  def change
    add_column :apps, :uses_stable_names, :boolean, default: false, null: false
  end
end
