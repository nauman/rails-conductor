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
  # FleetRecipes arrives in PR #34. If this migration reaches main first, the next
  # deploy dies inside db:migrate on a bare NameError — and because Conductor
  # deploys itself through that path, the symptom is not "the migration did not
  # run", it is "nothing can deploy". A sentence beats a constant lookup failure.
  def up
    unless defined?(FleetRecipes)
      raise "SeedFleetRecipes requires FleetRecipes, which lands in PR #34. " \
            "Deploy #34 before this migration."
    end

    FleetRecipes.seed!
  end

  def down
    # Deliberately not destructive: by the time anyone rolls this back, these rows
    # may carry operator edits that exist nowhere else.
  end
end
