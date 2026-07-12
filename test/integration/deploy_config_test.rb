require "test_helper"

class DeployConfigTest < ActionDispatch::IntegrationTest
  def sign_in_as(user)
    ps = Passwordless::Session.create!(authenticatable: user)
    get "/users/sign_in/#{ps.identifier}/#{ps.token}"
  end

  setup do
    @user = User.create!(email: "dc@example.com")
    @org = Organization.create_for(@user, name: "Mine")
    @key = SshKey.create!(name: "k", private_key: valid_private_key, organization: @org)
    @server = @org.servers.create!(name: "fleet", status: "online", ip_address: "192.0.2.10",
                                   ssh_key: @key, ssh_user: "deploy")
    @application = @org.apps.create!(name: "Appone", slug: "appone", server: @server, deploy_method: "kamal",
                             repository_url: "https://github.com/pavelabs/appone.git", branch: "main",
                             domain: "appone.example.com", port: 3000, ssl_enabled: true)
    @application.env_variables.create!(key: "SECRET_KEY_BASE", value: "raw_value", secret: true)
    @user.organizations.update_all(onboarded_at: Time.current)
    sign_in_as(@user)
  end

  test "kamal app renders self-describing deploy config with real values, no placeholders, no raw secrets" do
    get deploy_config_app_path(@application)
    assert_response :success
    assert_match "config/deploy.production.yml", @response.body
    assert_match "192.0.2.10", @response.body
    assert_match ".kamal/secrets.production", @response.body
    assert_match "localvault get appone.SECRET_KEY_BASE", @response.body
    refute_match(/YOUR_SERVER_IP/, @response.body)
    refute_match(/raw_value/, @response.body)
  end

  test "non-kamal app is redirected (Kamal-only for now)" do
    @application.update!(deploy_method: "native")
    get deploy_config_app_path(@application)
    assert_redirected_to app_path(@application)
  end

  test "toggling self_describing flips the flag (default off)" do
    refute @application.self_describing?
    patch toggle_self_describing_app_path(@application)
    assert @application.reload.self_describing?
    patch toggle_self_describing_app_path(@application)
    refute @application.reload.self_describing?
  end
end
