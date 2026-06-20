require "test_helper"

# Auto-deploy on git push: a verified SCM webhook enqueues the same DeployAppJob
# the UI/MCP use, gated on a valid HMAC signature, auto_deploy, and branch match.
class AutoDeployWebhookTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(email: "o@example.com")
    @org = Organization.create_for(@user, name: "Org")
    @app_rec = @org.apps.create!(name: "app", slug: "app", branch: "main",
                             repository_url: "https://github.com/acme/app.git",
                             auto_deploy: true)
  end

  def post_push(app, ref: "refs/heads/main", secret: nil)
    body = { ref: ref }.to_json
    secret ||= app.webhook_secret
    sig = "sha256=" + OpenSSL::HMAC.hexdigest("SHA256", secret, body)
    post "/webhooks/github/#{app.id}", params: body,
         headers: { "X-Hub-Signature-256" => sig, "Content-Type" => "application/json" }
  end

  test "a verified push on the deploy branch creates a deployment" do
    assert_difference -> { @app_rec.deployments.count }, 1 do
      post_push(@app_rec)
    end
    assert_response :accepted
  end

  test "an invalid signature is rejected and does not deploy" do
    assert_no_difference -> { @app_rec.deployments.count } do
      post_push(@app_rec, secret: "wrong-secret")
    end
    assert_response :unauthorized
  end

  test "auto_deploy off does not deploy" do
    @app_rec.update!(auto_deploy: false)
    assert_no_difference -> { @app_rec.deployments.count } do
      post_push(@app_rec)
    end
    assert_response :ok
  end

  test "a push to a non-deploy branch is ignored" do
    assert_no_difference -> { @app_rec.deployments.count } do
      post_push(@app_rec, ref: "refs/heads/feature-x")
    end
    assert_response :ok
  end

  test "debounce: skips when a deploy is already in progress" do
    @app_rec.deployments.create!(status: "building")
    assert_no_difference -> { @app_rec.deployments.count } do
      post_push(@app_rec)
    end
    assert_response :ok
  end

  test "an unknown app returns 404" do
    body = { ref: "refs/heads/main" }.to_json
    sig = "sha256=" + OpenSSL::HMAC.hexdigest("SHA256", "x", body)
    post "/webhooks/github/999999", params: body,
         headers: { "X-Hub-Signature-256" => sig, "Content-Type" => "application/json" }
    assert_response :not_found
  end

  test "each app gets a webhook secret on create" do
    assert @app_rec.webhook_secret.present?
    assert_equal "/webhooks/github/#{@app_rec.id}", @app_rec.webhook_path
  end
end
