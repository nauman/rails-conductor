require "test_helper"

# Members of one org must not reach another org's resources by guessing IDs.
class CrossTenantIsolationTest < ActionDispatch::IntegrationTest
  def sign_in_as(user)
    user.organizations.update_all(onboarded_at: Time.current)
    ps = Passwordless::Session.create!(authenticatable: user)
    get "/users/sign_in/#{ps.identifier}/#{ps.token}"
  end

  setup do
    @me = User.create!(email: "me@example.com")
    @mine = Organization.create_for(@me, name: "Mine")

    other_user = User.create!(email: "other@example.com")
    @other = Organization.create_for(other_user, name: "Other")
    @other_key = @other.ssh_keys.create!(name: "k", private_key: valid_private_key)
    @other_server = @other.servers.create!(name: "other-box", status: "online", ip_address: "10.9.9.9", ssh_key: @other_key)
    @other_app = @other.apps.create!(name: "Other App", slug: "other-app", server: @other_server,
                                     deploy_method: "docker", repository_url: "https://github.com/x/y.git")
    @other_actor = other_user
    sign_in_as(@me)
  end

  test "cannot create an env var on another org's app (404)" do
    post app_env_variables_path(@other_app), params: { env_variable: { key: "X", value: "y", secret: "0" } }
    assert_response :not_found
    assert_equal 0, @other_app.env_variables.count
  end

  test "cannot view another org's deployment (404)" do
    dep = @other_app.deployments.create!(status: "succeeded")
    get deployment_path(dep)
    assert_response :not_found
  end

  test "cannot view another org's script run (404)" do
    script = Script.create!(name: "probe", body: "echo hi", script_type: "provision")
    run = ScriptRun.create!(server: @other_server, script: script, user: @other_actor)
    get script_run_path(run)
    assert_response :not_found
  end

  test "an app cannot be attached to another org's server (model validation)" do
    app = @mine.apps.new(name: "Mine App", slug: "mine-app", server: @other_server,
                         deploy_method: "docker", repository_url: "https://github.com/x/y.git")
    refute app.valid?
    assert_match(/same organization/, app.errors[:server].join)
  end

  test "the same SSH key name is allowed in two organizations" do
    @mine.ssh_keys.create!(name: "Conductor deploy key", private_key: valid_private_key)
    assert_nothing_raised do
      @other.ssh_keys.create!(name: "Conductor deploy key", private_key: valid_private_key)
    end
  end
end
