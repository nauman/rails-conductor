require "test_helper"

# Q-07-1 (spec 08): a deploy that happens in CI rather than through Conductor
# reports itself back over the per-app HMAC webhook so it becomes a real
# Deployment row. Without it, Conductor's own dashboard row reads stale forever
# because CI-driven deploys were never recorded.
class WebhooksControllerReportDeploymentTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @user = User.create!(email: "wh@example.com")
    @org = Organization.create_for(@user, name: "Acme")
    key = SshKey.create!(name: "k", private_key: valid_private_key, organization: @org)
    @server = @org.servers.create!(name: "box", status: "online", ip_address: "10.0.0.1", ssh_key: key)
    @target = @org.apps.create!(name: "Conductor", slug: "conductor", server: @server)
  end

  def signed_post(payload, secret: @target.webhook_secret)
    body = payload.to_json
    sig = "sha256=" + OpenSSL::HMAC.hexdigest("SHA256", secret, body)
    post "/webhooks/#{@target.id}/deployment",
         params: body, headers: { "Content-Type" => "application/json", "X-Hub-Signature-256" => sig }
  end

  test "a signed success report creates a succeeded Deployment and marks the app running" do
    assert_difference -> { @target.deployments.count }, 1 do
      signed_post({ status: "succeeded", commit_sha: "abc123", release_version: "v42" })
    end
    assert_response :created
    d = @target.deployments.last
    assert_equal "succeeded", d.status
    assert_equal "ci", d.kind
    assert_equal "abc123", d.commit_sha
    assert_equal "v42", d.release_version
    assert_equal @server, d.server
    assert d.completed_at.present?
    assert_equal "running", @target.reload.status
    assert @target.deployed_at.present?
  end

  test "a signed failure report records the failure without touching app status" do
    @target.update!(status: "running")
    signed_post({ status: "failed", commit_sha: "def456", cause_class: "infrastructure" })
    assert_response :created
    d = @target.deployments.last
    assert_equal "failed", d.status
    assert_equal "infrastructure", d.cause_class
    # deploy_health now reflects the real latest state instead of reading stale.
    assert_equal "failed", @target.reload.deploy_health
  end

  test "an unknown cause_class is dropped, never invented" do
    signed_post({ status: "failed", cause_class: "operator_typo" })
    assert_response :created
    assert_nil @target.deployments.last.cause_class
  end

  test "an invalid status is rejected and records nothing" do
    assert_no_difference -> { @target.deployments.count } do
      signed_post({ status: "deploying" })
    end
    assert_response :unprocessable_entity
  end

  test "a bad signature is unauthorized and records nothing" do
    assert_no_difference -> { @target.deployments.count } do
      signed_post({ status: "succeeded" }, secret: "wrong-secret")
    end
    assert_response :unauthorized
  end

  test "an unknown app is not found" do
    body = { status: "succeeded" }.to_json
    sig = "sha256=" + OpenSSL::HMAC.hexdigest("SHA256", "x", body)
    post "/webhooks/0/deployment",
         params: body, headers: { "Content-Type" => "application/json", "X-Hub-Signature-256" => sig }
    assert_response :not_found
  end

  # The report must NOT trigger a deploy — it records one that already ran.
  test "reporting never enqueues a DeployAppJob" do
    assert_no_enqueued_jobs only: DeployAppJob do
      signed_post({ status: "succeeded" })
    end
  end
end
