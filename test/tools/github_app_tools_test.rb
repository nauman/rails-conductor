require "test_helper"

class GithubAppToolsTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "gat@example.com", admin: true)
  end

  def pem = file_fixture("test_github_app.pem").read

  test "set_github_app validates the key and stores a global credential" do
    res = SetGithubAppTool.new(user: @user).call("app_id" => "987", "private_key" => pem)
    assert res.success?, res.error
    cred = Credential.for_provider("github_app").first
    assert_equal "987", cred.api_key
    assert_nil cred.organization_id
  end

  test "set_github_app rejects an invalid private key" do
    res = SetGithubAppTool.new(user: @user).call("app_id" => "1", "private_key" => "nope")
    refute res.success?
    assert_includes res.error, "not a valid PEM"
  end

  test "github_installations fails clearly when no app configured" do
    res = GithubInstallationsTool.new(user: @user).call({})
    refute res.success?
    assert_includes res.error, "No GitHub App configured"
  end

  test "github_installations checks a repo via the configured app" do
    Credential.create!(provider: "github_app", name: "GitHub App", api_key: "1", api_secret: pem, active: true)
    fake = Object.new
    def fake.installation_id_for(repo) = 55
    GithubApp.stub(:from_config, fake) do
      res = GithubInstallationsTool.new(user: @user).call("repo" => "intellectaco/kuickr")
      assert res.success?
      assert res.value[:reachable]
      assert_equal 55, res.value[:installation_id]
    end
  end
end
