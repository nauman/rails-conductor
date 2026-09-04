require "test_helper"

# ADR 0007 says a finding must cite the ritual that resolves it. It has been citing
# `recipe_id` into a channel with no way to dereference it — the pointer was built,
# the lookup was not. A citation nobody can follow is a slightly better remedy string.
class RitualLibraryTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "rl@example.com")
    Organization.create_for(@user, name: "Acme")
    FleetRecipes.seed!
  end

  def call(input) = ConductorRunbookTool.new(user: @user).call(input)

  test "list returns the library an agent is pointed at" do
    result = call("action" => "list_rituals")

    assert result.success?, result.error
    ids = result.value[:rituals].map { |r| r[:id] }
    assert_includes ids, "diagnose-live-orphan"
    assert_equal FleetRecipes.recipe_ids.sort, ids.sort
  end

  # Every finding kind that cites a ritual must cite one that can be fetched.
  test "every ritual a finding cites is retrievable" do
    FleetRecipes::FINDING_RECIPES.each_value do |recipe_id|
      result = call("action" => "get_ritual", "recipe_id" => recipe_id)

      assert result.success?, "#{recipe_id}: #{result.error}"
      assert_equal recipe_id, result.value[:id]
      assert result.value[:checklist].any?, "#{recipe_id} has no steps"
    end
  end

  test "get returns the reasoning, not only the steps" do
    result = call("action" => "get_ritual", "recipe_id" => "diagnose-live-orphan")

    assert result.value[:description].present?, "the hidden truth is the point of a ritual"

    step = result.value[:checklist].first
    assert step[:id].present?, "steps need addressable ids"
    assert step[:text].present?, "a step with no text is not a step"
  end

  # jazari's fetch returns a content-free EMPTY recipe for an unknown id rather than
  # raising, so passing that straight through would answer a typo with a valid-looking
  # empty ritual.
  test "an unknown ritual is a failure, not an empty one" do
    result = call("action" => "get_ritual", "recipe_id" => "no-such-ritual")

    assert_not result.success?
    assert_match(/no-such-ritual/, result.error)
  end

  test "list reports which rituals an operator has customised" do
    record = Jazari::RecipeRecord.find_by(recipe_id: "diagnose-live-orphan")
    record.update!(description: "#{record.description} — and one more thing")

    row = call("action" => "list_rituals").value[:rituals].find { |r| r[:id] == "diagnose-live-orphan" }

    assert row[:custom], "an edited ritual no longer tracks the canon and must say so"
  end

  # Divergence has to notice a STEP edit too — comparing only the prose would call a
  # rewritten checklist canonical.
  test "an edited step counts as customised" do
    record = Jazari::RecipeRecord.find_by(recipe_id: "diagnose-release-drift")
    steps = record.checklist
    steps.first["text"] = "something an operator decided instead"
    record.update!(checklist: steps)

    row = call("action" => "list_rituals").value[:rituals].find { |r| r[:id] == "diagnose-release-drift" }

    assert row[:custom]
  end

  # A read-scoped token is the whole audience for a citation an agent follows
  # mid-diagnosis. The tool tests call the class directly and so never crossed this
  # gate — the feature would have been invisible to exactly the caller it is for.
  test "a read-scoped token may reach the library" do
    assert ToolAuthorization.read_only?("conductor_runbook", "list_rituals")
    assert ToolAuthorization.read_only?("conductor_runbook", "get_ritual")
    assert_not ToolAuthorization.read_only?("conductor_runbook", "set_runbook")
  end

  # jazari's recipes table is shared. Serving any id in it would hand back rows this
  # repo never shipped and cannot describe, including anything another tenant stored.
  test "only the canonical library is served" do
    Jazari::RecipeRegistry.seed!([ {
      id: "someone-elses-recipe", version: 1, topic: "not ours",
      description: "private", checklist: [ { id: "s1", text: "step" } ]
    } ])

    result = call("action" => "get_ritual", "recipe_id" => "someone-elses-recipe")

    assert_not result.success?
    assert_empty call("action" => "list_rituals").value[:rituals].select { |r| r[:id] == "someone-elses-recipe" }
  end

  # Divergence must notice everything a reader acts on, not only the prose.
  test "a renamed topic or a step turned optional counts as customised" do
    { topic: ->(r) { r.update!(topic: "renamed") },
      required: ->(r) {
        steps = r.checklist
        steps.first["required"] = false
        r.update!(checklist: steps)
      } }.each do |what, edit|
      FleetRecipes.seed!
      record = Jazari::RecipeRecord.find_by(recipe_id: "diagnose-build-placement")
      edit.call(record)

      assert FleetRecipes.diverged?(record.reload), "#{what} must count as a customisation"
      record.destroy
    end
  end

  test "an untouched ritual is not reported as customised" do
    row = call("action" => "list_rituals").value[:rituals].find { |r| r[:id] == "diagnose-release-drift" }

    assert_not row[:custom]
  end
end
