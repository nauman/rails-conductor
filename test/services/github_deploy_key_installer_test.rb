require "test_helper"

class GithubDeployKeyInstallerTest < ActiveSupport::TestCase
  setup do
    user = User.create!(email: "gh@example.com")
    @org = Organization.create_for(user, name: "Acme")
    @app = @org.apps.create!(name: "Kuickr", slug: "kuickr", deploy_method: "kamal",
                             repository_url: "https://github.com/pavelabs/kuickr.git")
    @app.create_deploy_key!(public_key: "ssh-ed25519 AAAA conductor-kuickr", private_key: valid_private_key)
  end

  class FakeClient
    attr_reader :added
    def add_deploy_key(**kwargs) = (@added = kwargs; { "id" => 1 })
  end

  test "installs the deploy key via the org GitHub token" do
    @org.credentials.create!(provider: "github", name: "GitHub", api_key: "ghp_x", active: true)
    client = FakeClient.new

    result = GithubDeployKeyInstaller.install(@app, client: client)

    assert result[:installed]
    assert_equal "pavelabs/kuickr", result[:repo]
    assert_equal "pavelabs/kuickr", client.added[:repo]
    assert_equal "conductor-kuickr", client.added[:title]
    assert client.added[:read_only]
  end

  test "no-ops with a reason when the org has no GitHub token" do
    result = GithubDeployKeyInstaller.install(@app, client: FakeClient.new)
    refute result[:installed]
    assert_includes result[:reason], "No GitHub token"
  end

  test "reports GitHub API errors without raising" do
    @org.credentials.create!(provider: "github", name: "GitHub", api_key: "ghp_x", active: true)
    failing = Object.new
    def failing.add_deploy_key(**) = raise(GithubClient::Error, "GitHub API 403: forbidden")

    result = GithubDeployKeyInstaller.install(@app, client: failing)
    refute result[:installed]
    assert_includes result[:reason], "403"
  end

  test "App#github_repo parses https and ssh forms" do
    assert_equal "pavelabs/kuickr", @app.github_repo
    @app.update!(repository_url: "git@github.com:pavelabs/kuickr.git")
    assert_equal "pavelabs/kuickr", @app.github_repo
  end
end
