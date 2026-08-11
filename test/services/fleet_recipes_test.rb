require "test_helper"

# The content behind FleetCanon's pointers. jazari owns the API and ships zero
# recipe content by design, so the rituals live here — and every pointer the canon
# can name must have a recipe behind it, or resolve returns the empty fallback and
# an operator reads "no ritual" as "no ritual needed".
class FleetRecipesTest < ActiveSupport::TestCase
  test "every recipe the canon can point at has content behind it" do
    missing = FleetCanon::RECIPES.values - FleetRecipes.recipe_ids

    assert_empty missing, "canon points at recipes with no content: #{missing.inspect}"
  end

  test "seeding creates each recipe with a topic and a non-empty checklist" do
    FleetRecipes.seed!

    FleetRecipes.recipe_ids.each do |id|
      recipe = Jazari::RecipeRegistry.fetch(id)
      assert recipe.topic.present?, "#{id} has no topic"
      assert recipe.checklist.any?, "#{id} has an empty checklist"
    end
  end

  test "reseeding never overwrites an operator's edit" do
    FleetRecipes.seed!
    record = Jazari::RecipeRecord.find_by!(recipe_id: "caddy-mode-app")
    record.update!(topic: "Operator renamed this")

    FleetRecipes.seed!

    assert_equal "Operator renamed this", record.reload.topic,
      "create-if-missing means the operator's edit is the truth once it exists"
  end

  test "item ids are stable strings, not generated tokens" do
    FleetRecipes::RECIPES.each do |recipe|
      recipe[:checklist].each do |item|
        assert item[:id].present?, "#{recipe[:id]} has an item with no id"
        assert_match(/\A[a-z][a-z0-9-]*\z/, item[:id],
          "#{recipe[:id]}/#{item[:id]} must be a readable stable id — an id is how MCP addresses a step")
      end
    end
  end

  test "the caddy-mode ritual carries the lesson that cost three deploys" do
    checklist = FleetRecipes::RECIPES.find { |r| r[:id] == "caddy-mode-app" }[:checklist]
    texts = checklist.map { |i| i[:text] }.join(" ")

    assert_match(/_replaced_/, texts, "the renamed-incumbent trap must be a step, not folklore")
    assert_match(/latest|sha/i, texts, "the mutable-tag trap must be a step")
  end
end
