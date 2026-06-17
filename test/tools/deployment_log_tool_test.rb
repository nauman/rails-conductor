require "test_helper"

class DeploymentLogToolTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "dl@example.com", admin: true)
    @org = Organization.create_for(@user, name: "Acme")
    @app = @org.apps.create!(name: "Kuickr", slug: "kuickr", deploy_method: "kamal")
    @deployment = @app.deployments.create!(status: "deploying", log: "line1\nline2\nline3\n")
  end

  test "returns the latest deployment's status and log by app name" do
    res = DeploymentLogTool.new(user: @user).call("app_name" => "Kuickr")
    assert res.success?
    assert_equal @deployment.id, res.value[:deployment_id]
    assert_equal "deploying", res.value[:status]
    assert_includes res.value[:log], "line2"
    assert_equal @org, res.value[:_organization]
  end

  test "tails the last N log lines" do
    res = DeploymentLogTool.new(user: @user).call("deployment_id" => @deployment.id, "tail" => 1)
    assert_equal "line3\n", res.value[:log]
  end

  test "fails cleanly when nothing matches" do
    res = DeploymentLogTool.new(user: @user).call("app_name" => "Ghost")
    refute res.success?
  end
end
