# The same failure the original seed migration was written for, one layer along.
#
# 20260811090000 seeded the five SHAPE recipes and has already run everywhere, so
# it will never run again — and ADR 0007's four DIAGNOSTIC recipes arrived after
# it. Findings now hand agents a recipe_id, and without this those ids point at
# rows that were never created: `resolve` falls back to the empty recipe and reads
# as "this finding has no ritual", which is exactly the silence the ADR exists to
# end.
#
# The guard in FleetSituation is a constant lookup, so it proves the id is spelled
# right and nothing about whether anything is behind it. That distinction is what
# made the first version of this bug invisible.
#
# Safe to re-run: seed! is create-if-missing, so an operator's edit wins once the
# row exists.
class SeedDiagnosticRecipes < ActiveRecord::Migration[8.0]
  def up
    raise "SeedDiagnosticRecipes requires FleetRecipes" unless defined?(FleetRecipes)

    FleetRecipes.seed!
  end

  def down
    # Not destructive: these rows may carry operator edits that exist nowhere else.
  end
end
