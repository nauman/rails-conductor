require "test_helper"

class InstallWebhookToolTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "wh-tool@example.com", admin: true)
    @org = Organization.create_for(@user, name: "Acme")
    @app = @org.apps.create!(name: "Appone", slug: "appone", deploy_method: "kamal",
                             repository_url: "https://github.com/pavelabs/appone.git")
  end

  test "install_webhook installs the hook and enables auto_deploy" do
    stub = ->(app, **) { { installed: true, repo: "pavelabs/appone", webhook_url: "https://c/webhooks/github/#{app.id}", hook_id: 5 } }
    GithubWebhookInstaller.stub(:install, stub) do
      res = ConductorAppConfigTool.new(user: @user).call("action" => "install_webhook", "app_id" => @app.id)
      assert res.success?, res.error
      assert res.value[:auto_deploy]
      assert_equal "pavelabs/appone", res.value[:repo]
      assert @app.reload.auto_deploy?, "auto_deploy should be enabled"
    end
  end

  test "reports the installer failure and does NOT enable auto_deploy" do
    stub = ->(*, **) { { installed: false, reason: "No GitHub token configured for this org" } }
    GithubWebhookInstaller.stub(:install, stub) do
      res = ConductorAppConfigTool.new(user: @user).call("action" => "install_webhook", "app_name" => "Appone")
      refute res.success?
      assert_includes res.error, "No GitHub token"
      refute @app.reload.auto_deploy?
    end
  end

  test "requires a repository_url" do
    @app.update_column(:repository_url, nil)
    res = ConductorAppConfigTool.new(user: @user).call("action" => "install_webhook", "app_id" => @app.id)
    refute res.success?
    assert_includes res.error, "repository_url"
  end

  test "unknown app is reported" do
    res = ConductorAppConfigTool.new(user: @user).call("action" => "install_webhook", "app_name" => "Ghost")
    refute res.success?
    assert_includes res.error, "App not found"
  end
end
