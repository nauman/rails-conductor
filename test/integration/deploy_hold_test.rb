require "test_helper"

# The deploy preflight's "threads" gate is an explicit deploy_hold an operator
# toggles from the app page. These cover the toggle action (which previously
# crashed because it wasn't in the set_app callback) and that a held app shows
# the blocked state instead of a Deploy button.
#
# NB: the app record is @application, not @app — @app is the Rack app in an
# ActionDispatch::IntegrationTest and clobbering it breaks get/post.
class DeployHoldTest < ActionDispatch::IntegrationTest
  def sign_in_as(user)
    ps = Passwordless::Session.create!(authenticatable: user)
    get "/users/sign_in/#{ps.identifier}/#{ps.token}"
  end

  setup do
    @user = User.create!(email: "hold@example.com")
    @org = Organization.create_for(@user, name: "Mine")
    @key = SshKey.create!(name: "k", private_key: valid_private_key, organization: @org)
    @server = @org.servers.create!(name: "fleet", status: "online", ip_address: "192.0.2.10",
                                   ssh_key: @key, ssh_user: "deploy")
    @application = @org.apps.create!(name: "Appone", slug: "appone", server: @server, deploy_method: "kamal",
                                     repository_url: "https://github.com/me/appone.git")
    @user.organizations.update_all(onboarded_at: Time.current)
    sign_in_as(@user)
  end

  test "toggling the hold sets and clears it (does not crash on a nil app)" do
    patch toggle_deploy_hold_app_path(@application), params: { reason: "thread owed" }
    assert @application.reload.deploy_hold?
    assert_equal "thread owed", @application.deploy_hold_reason

    patch toggle_deploy_hold_app_path(@application)
    refute @application.reload.deploy_hold?
    assert_nil @application.deploy_hold_reason
  end

  test "a held app shows Deploy blocked instead of a Deploy button" do
    @application.update!(deploy_hold: true, deploy_hold_reason: "thread owed")
    get app_path(@application)
    assert_response :success
    assert_match "Deploy blocked", @response.body
    assert_match "Deploy Preflight", @response.body
  end

  test "toggling seed-on-next-deploy sets and clears the one-shot flag" do
    patch toggle_seed_on_next_deploy_app_path(@application)
    assert @application.reload.seed_on_next_deploy?

    patch toggle_seed_on_next_deploy_app_path(@application)
    refute @application.reload.seed_on_next_deploy?
  end

  test "deploying a held app is blocked; forcing overrides" do
    @application.update!(deploy_hold: true)
    assert_no_enqueued_jobs { post deploy_app_path(@application) }
    assert_match(/blocked/i, flash[:alert].to_s)

    assert_enqueued_with(job: DeployAppJob) { post deploy_app_path(@application, force: true) }
  end
end
