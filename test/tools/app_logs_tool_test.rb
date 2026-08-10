require "test_helper"

# Conductor promises per-app visibility, but every log read until now returned
# Conductor's OWN record of an operation (script runs, deployment transcripts) —
# never what the running app said. Diagnosing a live incident therefore meant
# dropping to SSH, which is exactly the guardrail that blocks app-scoped agents.
class AppLogsToolTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "al@example.com", admin: true)
    @org = Organization.create_for(@user, name: "Logs Co")
    @server = Server.create!(name: "log-box", status: "online", organization: @org,
                             ip_address: "10.0.0.9", ssh_user: "deploy")
    @app = @org.apps.create!(name: "Logged", slug: "logged", server: @server, deploy_method: "kamal")
  end

  # The fake stands in for the container lookup + `docker logs` call.
  def tool(output:, spy: nil)
    AppLogsTool.new(user: @user, runner: ->(cmd) { spy&.push(cmd); output })
  end

  test "returns the running container's log lines for an app" do
    res = tool(output: "web-1\n---\nI, [2026-08-10] Started GET \"/up\"\nCompleted 200 OK in 4ms").call("app_name" => "Logged")

    assert res.success?, res.error
    assert_equal "Logged", res.value[:app]
    assert_match(/Started GET/, res.value[:log])
    assert_equal "log-box", res.value[:server]
  end

  test "asks for a bounded tail and passes it through" do
    spy = []
    tool(output: "web-1\n---\nline", spy: spy).call("app_name" => "Logged", "tail" => 25)

    assert spy.any? { |c| c.include?("--tail 25") }, "expected the tail to reach docker logs: #{spy.inspect}"
  end

  test "reports the retention window so a rotated-away incident is not read as silence" do
    res = tool(output: "web-1\n---\nline").call("app_name" => "Logged")

    assert res.value.key?(:covers_from),
      "an empty or short log must say how far back it reaches — absent evidence is not evidence"
  end

  test "an app with no server is refused with a clear reason rather than an empty log" do
    homeless = @org.apps.create!(name: "Homeless", slug: "homeless", deploy_method: "docker")
    res = tool(output: "").call("app_name" => "Homeless")

    refute res.success?
    assert_match(/no server/i, res.error)
  end

  test "a missing app is refused" do
    refute tool(output: "").call("app_name" => "Nope").success?
  end

  test "conductor_read exposes it as the app_logs action and it stays read-only" do
    assert_equal AppLogsTool, ConductorReadTool::ACTIONS["app_logs"]
    assert ToolAuthorization.read_only?("conductor_read", "app_logs")
  end
end
