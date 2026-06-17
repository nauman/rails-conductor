require "test_helper"

class GithubToolsTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "ght@example.com", admin: true)
    @org = Organization.create_for(@user, name: "Acme")
    @app = @org.apps.create!(name: "Kuickr", slug: "kuickr", deploy_method: "kamal",
                             repository_url: "https://github.com/pavelabs/kuickr.git")
  end

  test "set_github_token stores an org github credential" do
    res = SetGithubTokenTool.new(user: @user).call("token" => "ghp_secret")
    assert res.success?, res.error
    assert_equal "ghp_secret", @org.reload.github_token
    assert_equal @org, res.value[:_organization]
  end

  test "set_github_token updates the existing credential rather than duplicating" do
    SetGithubTokenTool.new(user: @user).call("token" => "ghp_1")
    assert_no_difference -> { @org.credentials.for_provider("github").count } do
      SetGithubTokenTool.new(user: @user).call("token" => "ghp_2")
    end
    assert_equal "ghp_2", @org.reload.github_token
  end

  test "generate_deploy_key reports not-auto-added when no github token is set" do
    res = GenerateDeployKeyTool.new(user: @user).call("app_name" => "Kuickr")
    assert res.success?
    refute res.value[:github_installed]
    assert_match(/\Assh-ed25519 /, res.value[:public_key])
  end

  test "generate_deploy_key auto-installs when a github token is configured" do
    @org.credentials.create!(provider: "github", name: "GitHub", api_key: "ghp_x", active: true)
    fake = Object.new
    def fake.add_deploy_key(**) = { "id" => 1 }

    GithubClient.stub(:new, fake) do
      res = GenerateDeployKeyTool.new(user: @user).call("app_name" => "Kuickr")
      assert res.value[:github_installed], res.value[:github_detail]
      assert_equal "pavelabs/kuickr", res.value[:github_detail]
    end
  end
end
