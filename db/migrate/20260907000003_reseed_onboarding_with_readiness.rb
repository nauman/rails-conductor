# The onboarding ritual gained a first step (check readiness before anything else).
# Seeding is create-if-missing, so an existing row keeps the old text — and this is
# the document an agent reads before standing up an app, so stale guidance here is
# guidance that gets followed.
#
# Only replaces text nobody has customised; an operator's edit wins.
class ReseedOnboardingWithReadiness < ActiveRecord::Migration[8.0]
  def up
    return unless defined?(FleetRecipes) && defined?(Jazari::RecipeRecord)

    canon = FleetRecipes::RECIPES.find { |r| r[:id].to_s == "onboard-new-app" }
    record = Jazari::RecipeRecord.find_by(recipe_id: "onboard-new-app")
    return FleetRecipes.seed! if canon.nil? || record.nil?
    return if FleetRecipes.diverged?(record)

    record.update!(description: canon[:description],
                   checklist: Jazari::Checklist.normalize(canon[:checklist]).map { |i| i.transform_keys(&:to_s) })
  end

  def down
    # Not destructive.
  end
end
