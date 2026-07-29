require "test_helper"

# conductor_app action=cancel — reap a stuck in-progress deployment so the app can
# deploy again. Needed because a job-retry race can orphan a deployment at
# "deploying" (its driver process gone), and the one-active-deploy-per-app index
# then blocks every future deploy with no way to clear it.
class CancelDeploymentToolTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "cancel@example.com", admin: true)
    @org = Organization.create_for(@user, name: "Acme")
    key = SshKey.create!(name: "k", private_key: valid_private_key, organization: @org)
    @server = @org.servers.create!(name: "box", status: "online", ip_address: "10.0.0.1", ssh_key: key)
    @app = @org.apps.create!(name: "Appone", slug: "appone", server: @server, deploy_method: "kamal",
                             repository_url: "https://github.com/x/y.git")
  end

  def run_tool(**over)
    ConductorAppTool.new(user: @user).call({ "action" => "cancel" }.merge(over.transform_keys(&:to_s)))
  end

  test "cancels a stuck in-progress deployment and frees the app to deploy again" do
    stuck = @app.deployments.create!(status: "deploying", kind: "transfer")
    res = run_tool(deployment_id: stuck.id)
    assert res.success?, res.error
    assert_equal "cancelled", stuck.reload.status
    assert stuck.completed_at.present?
    # The one-active-deploy index is now free: a new in-progress deploy can be created.
    assert_nothing_raised { @app.deployments.create!(status: "pending") }
  end

  test "with no deployment_id it cancels the app's latest in-progress deployment" do
    @app.deployments.create!(status: "deploying", kind: "transfer")
    res = run_tool(app_name: "Appone")
    assert res.success?, res.error
    assert_equal "cancelled", @app.deployments.order(:created_at).last.status
  end

  test "refuses to cancel a terminal deployment (nothing in progress)" do
    done = @app.deployments.create!(status: "succeeded")
    res = run_tool(deployment_id: done.id)
    refute res.success?
    assert_match(/not in progress/i, res.error)
    assert_equal "succeeded", done.reload.status
  end

  test "an unknown deployment is a clean failure" do
    res = run_tool(deployment_id: 999_999)
    refute res.success?
    assert_match(/not found/i, res.error)
  end
end
