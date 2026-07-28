require "test_helper"

# Spec 08 — the fleet has to update itself. Metrics arrive from a background job and
# deploys finish minutes after you clicked; if neither pushes, the dashboard is only ever
# as fresh as the last reload, which is what makes people trust `htop` over the control
# plane. Both broadcast onto ONE per-org stream so the page needs a single subscription.
class LiveDashboardBroadcastTest < ActiveSupport::TestCase
  require "turbo/broadcastable/test_helper"
  include Turbo::Broadcastable::TestHelper
  setup do
    @user = User.create!(email: "live@example.com")
    @org = Organization.create_for(@user, name: "Acme")
    @key = SshKey.create!(name: "k", private_key: valid_private_key, organization: @org)
    @server = @org.servers.create!(name: "box", status: "online", ip_address: "10.0.0.1",
                                   ssh_key: @key, ssh_user: "deploy")
    @app = @org.apps.create!(name: "Appone", slug: "appone", server: @server)
  end

  def dashboard_stream = [ @org, :dashboard ]

  test "metrics landing pushes the server card" do
    assert_turbo_stream_broadcasts(dashboard_stream, count: 1) do
      @server.update!(cpu_percent: 63, metrics_updated_at: Time.current)
    end
  end

  test "an unrelated server edit does not spam the dashboard" do
    assert_no_turbo_stream_broadcasts(dashboard_stream) do
      @server.update!(name: "box-renamed")
    end
  end

  test "starting a deploy flips the app's row without a reload" do
    assert_turbo_stream_broadcasts(dashboard_stream, count: 1) do
      @app.deployments.create!(user: @user, status: "deploying")
    end
  end

  test "finishing a deploy pushes the row again" do
    deployment = @app.deployments.create!(user: @user, status: "deploying")

    assert_turbo_stream_broadcasts(dashboard_stream, count: 1) do
      deployment.update!(status: "succeeded")
    end
  end

  test "a deployment edit that isn't a status change stays quiet" do
    deployment = @app.deployments.create!(user: @user, status: "deploying") # 1 broadcast

    deployment.update!(log: "more output")

    # assert_no_turbo_stream_broadcasts counts EVERY payload on the stream, not just
    # those inside a block — so the create above would fail it. "Still exactly one"
    # is the honest way to say the log edit broadcast nothing.
    assert_turbo_stream_broadcasts(dashboard_stream, count: 1)
  end

  # The broadcast renders the same partial the page does, so a helper that blows up on a
  # never-deployed app would break the live path only — the worst kind of bug to find in
  # production. Render it here with the awkward states.
  test "the broadcast partial renders for every deploy-health state" do
    %w[succeeded failed blocked deploying].each do |status|
      app = @org.apps.create!(name: "A#{status}", slug: "a-#{status}", server: @server)
      app.deployments.create!(user: @user, status: status)

      html = ApplicationController.render(partial: "dashboard/app_row", locals: { app: app.reload })
      assert_includes html, app.name
    end

    never = @org.apps.create!(name: "Never", slug: "never", server: @server)
    html = ApplicationController.render(partial: "dashboard/app_row", locals: { app: never })
    assert_includes html, "not deployed here"
  end
end
