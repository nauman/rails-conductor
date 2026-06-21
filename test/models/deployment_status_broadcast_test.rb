require "test_helper"
require "turbo/broadcastable/test_helper"

# Deployment status updates stream live to the deployment page — the badge moves
# through building → deploying → succeeded/failed with no page reload.
class DeploymentStatusBroadcastTest < ActiveSupport::TestCase
  include Turbo::Broadcastable::TestHelper

  setup do
    @org = Organization.create!(name: "Acme")
    @app = @org.apps.create!(name: "Kuickr", slug: "kuickr", deploy_method: "kamal")
    @deployment = @app.deployments.create!(status: "pending")
  end

  test "changing deployment status broadcasts a badge replace" do
    assert_turbo_stream_broadcasts(@deployment, count: 1) { @deployment.update!(status: "deploying") }
  end

  test "mark_deploying! broadcasts" do
    assert_turbo_stream_broadcasts(@deployment, count: 1) { @deployment.mark_deploying! }
  end

  test "a non-status change (e.g. appended log) does NOT broadcast a badge replace" do
    assert_no_turbo_stream_broadcasts(@deployment) { @deployment.update!(log: "a line") }
  end
end
