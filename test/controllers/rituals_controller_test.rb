require "test_helper"

# "Which rituals exist, and which have we customised?" was answerable by an agent
# over MCP and not by a person. Read-only is the useful minimum.
class RitualsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(email: "rc@example.com")
    org = Organization.create_for(@user, name: "Acme")
    org.update!(onboarded_at: Time.current)
    FleetRecipes.seed!
    session_record = Passwordless::Session.create!(authenticatable: @user)
    get "/users/sign_in/#{session_record.to_param}/#{session_record.token}"
  end

  test "index lists the library" do
    get rituals_path

    assert_response :success
    assert_select "body", /onboard-new-app/
  end

  test "show renders a ritual's reasoning and its steps" do
    get ritual_path("diagnose-live-orphan")

    assert_response :success
    assert_select "body", /Hidden truth/
  end

  test "an unknown ritual is a 404, not an empty page" do
    get ritual_path("no-such-ritual")

    assert_response :not_found
  end

  test "a customised ritual says so" do
    record = Jazari::RecipeRecord.find_by(recipe_id: "diagnose-live-orphan")
    record.update!(description: "operator rewrote this")

    get rituals_path

    assert_select "body", /customised/i
  end
end
