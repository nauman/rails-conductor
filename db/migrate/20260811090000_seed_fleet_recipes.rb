# FleetRecipes.seed! had no caller outside tests, so the five recipes existed in
# Ruby and never in a table — and FleetCanon points every app at one of them by id.
# A pointer with nothing behind it makes `resolve` fall back to the empty recipe,
# silently, which reads as "this app has no ritual" rather than as a missing seed.
#
# db/seeds.rb would not have fixed it: boot runs db:prepare, which seeds only on
# FIRST create, so an existing database never sees it. A data migration runs on
# every deploy that has not run it yet, which is what "seeded" has to mean here.
#
# Safe to re-run: seed! is create-if-missing, so an operator's edit wins once the
# row exists.
class SeedFleetRecipes < ActiveRecord::Migration[8.0]
  def up
    FleetRecipes.seed!
  end

  def down
    # Deliberately not destructive: by the time anyone rolls this back, these rows
    # may carry operator edits that exist nowhere else.
  end
end
