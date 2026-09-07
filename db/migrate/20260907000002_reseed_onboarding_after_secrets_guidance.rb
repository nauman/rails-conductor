# The onboarding ritual's secrets guidance changed (ADR 0016: the app owns its
# secrets; Conductor holds only infrastructure credentials). Seeding is
# create-if-missing, so an existing row keeps the OLD text — which is the wrong
# advice now, and the ritual is the thing an agent reads before standing up an app.
#
# This is the one case where overwriting is right: the recipe was never customised
# by an operator, and leaving it would actively mislead. If it HAS been customised,
# the edit wins and is left alone.
class ReseedOnboardingAfterSecretsGuidance < ActiveRecord::Migration[8.0]
  def up
    return unless defined?(FleetRecipes) && defined?(Jazari::RecipeRecord)

    canon = FleetRecipes::RECIPES.find { |r| r[:id].to_s == "onboard-new-app" }
    record = Jazari::RecipeRecord.find_by(recipe_id: "onboard-new-app")
    return FleetRecipes.seed! if canon.nil? || record.nil?

    # Only replace text nobody has edited. FleetRecipes.diverged? answers that.
    return if FleetRecipes.diverged?(record)

    record.update!(description: canon[:description],
                   checklist: Jazari::Checklist.normalize(canon[:checklist]).map { |i| i.transform_keys(&:to_s) })
  end

  def down
    # Not destructive.
  end
end
