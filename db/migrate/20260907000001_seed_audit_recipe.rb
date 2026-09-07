# Fourth instance of the same pattern: a recipe added after a seed migration has
# already run everywhere needs its own, because create-if-missing means the earlier
# one will never create it.
class SeedAuditRecipe < ActiveRecord::Migration[8.0]
  def up
    raise "SeedAuditRecipe requires FleetRecipes" unless defined?(FleetRecipes)

    FleetRecipes.seed!
  end

  def down
    # Not destructive: the row may carry operator edits that exist nowhere else.
  end
end
