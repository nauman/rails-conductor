# Same shape as 20260827030000 and 20260905000003: a recipe added after a seed
# migration has already run everywhere needs its own, because create-if-missing
# means the earlier one will never create it.
#
# This one is cited by `rake kamal:self_describing_audit`, so without it the audit
# would tell an operator to read a ritual that does not exist — the citation-nobody-
# can-follow problem ADR 0007 exists to end.
class SeedSelfDescribingMigrationRecipe < ActiveRecord::Migration[8.0]
  def up
    raise "SeedSelfDescribingMigrationRecipe requires FleetRecipes" unless defined?(FleetRecipes)

    FleetRecipes.seed!
  end

  def down
    # Not destructive: the row may carry operator edits that exist nowhere else.
  end
end
