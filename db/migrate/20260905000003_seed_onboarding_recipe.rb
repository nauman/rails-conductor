# The third instance of the same shape, which is now a pattern worth naming: a
# recipe added after a seed migration has already run everywhere needs its own,
# because create-if-missing means the earlier migration will never create it.
#
# This one seeds `onboard-new-app`. Unlike the diagnostics, no finding cites it —
# it is reached by an agent asking `conductor_runbook action=list_rituals` before
# standing up an app. So a missing row here fails differently and more quietly:
# nothing errors, the library is simply one ritual short, and the procedure most
# likely to be run by someone doing it for the first time is the one with no
# guidance behind it.
#
# Safe to re-run: seed! is create-if-missing, so an operator's edit wins.
class SeedOnboardingRecipe < ActiveRecord::Migration[8.0]
  def up
    raise "SeedOnboardingRecipe requires FleetRecipes" unless defined?(FleetRecipes)

    FleetRecipes.seed!
  end

  def down
    # Not destructive: this row may carry operator edits that exist nowhere else.
  end
end
