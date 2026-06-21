require "test_helper"

# The app edit form exposes a "This app is Conductor itself" toggle that sets
# self_managed, which engages SelfDeployReconciler for the app's deploys.
class AppSelfManagedTest < ActionDispatch::IntegrationTest
  def sign_in_as(user)
    ps = Passwordless::Session.create!(authenticatable: user)
    get "/users/sign_in/#{ps.identifier}/#{ps.token}"
  end

  setup do
    @user = User.create!(email: "sm@example.com")
    @org = Organization.create_for(@user, name: "Mine")
    @conductor = @org.apps.create!(name: "Conductor", slug: "conductor", deploy_method: "kamal")
    @user.organizations.update_all(onboarded_at: Time.current)
    sign_in_as(@user)
  end

  test "the edit form renders the self-managed toggle" do
    get edit_app_path(@conductor)
    assert_response :success
    assert_match "This app is Conductor itself", @response.body
  end

  test "checking the toggle marks the app self_managed" do
    patch app_path(@conductor), params: { app: { self_managed: "1" } }
    assert @conductor.reload.self_managed?
  end

  test "unchecking the toggle clears self_managed" do
    @conductor.update!(self_managed: true)
    patch app_path(@conductor), params: { app: { self_managed: "0" } }
    refute @conductor.reload.self_managed?
  end
end
