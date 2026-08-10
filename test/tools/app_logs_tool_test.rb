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

  # Application logs routinely carry credentials — a Bearer token in a request
  # header dump, a DATABASE_URL in a boot error, an api_key in a query string.
  # conductor_read is read-only for ANY read-scoped token, so returning raw log
  # text would hand every such token production secrets for every visible app.
  test "redacts bearer tokens, passwords, keys and connection strings" do
    raw = <<~LOG
      web-1
      ---
      Authorization: Bearer sk-live-abcdef1234567890
      Started GET "/x?api_key=SUPERSECRETVALUE&page=2"
      DATABASE_URL=postgres://user:hunter2@db.internal:5432/app
      password=hunter2 confirmed
      RAILS_MASTER_KEY=0123456789abcdef0123456789abcdef
    LOG

    log = tool(output: raw).call("app_name" => "Logged").value[:log]

    refute_match(/sk-live-abcdef1234567890/, log, "a bearer token must not survive")
    refute_match(/SUPERSECRETVALUE/, log, "a query-string api_key must not survive")
    refute_match(/hunter2/, log, "a password must not survive, in a URL or a pair")
    refute_match(/0123456789abcdef0123456789abcdef/, log, "a master key must not survive")
    assert_match(/\[REDACTED\]/, log, "the reader must see that something was removed")
    assert_match(/Started GET/, log, "ordinary log content must survive")
    assert_match(/page=2/, log, "a harmless parameter must survive")
  end

  test "reports that redaction happened so a reader knows the text is altered" do
    res = tool(output: "web-1\n---\nAuthorization: Bearer sk-live-xyz123456789").call("app_name" => "Logged")
    assert res.value[:redacted], "the payload must flag that secrets were removed"
  end

  test "a clean log is not flagged as redacted" do
    res = tool(output: "web-1\n---\nCompleted 200 OK in 4ms").call("app_name" => "Logged")
    refute res.value[:redacted]
  end

  # Codex review R-2 CONFIRMED these bypasses in the first redaction pass. Each
  # one is a live credential reaching any read-scoped MCP caller.
  test "redacts cookies, short values, JWTs and key-shaped blobs codex found leaking" do
    raw = <<~LOG
      web-1
      ---
      Cookie: session=abc123456; theme=dark
      Set-Cookie: sid=zzz999888; Path=/; HttpOnly
      Authorization: Bearer x
      jwt: eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.dBjftJeZ4CVPmB92K27uhbUJU1p1r
      aws_key: AKIAIOSFODNN7EXAMPLE
    LOG

    log = tool(output: raw).call("app_name" => "Logged").value[:log]

    refute_match(/abc123456/, log, "a Cookie header value must not survive")
    refute_match(/zzz999888/, log, "a Set-Cookie value must not survive")
    refute_match(/Bearer x\b/, log, "a short bearer value must not survive the 6-char floor")
    refute_match(/eyJhbGciOiJIUzI1NiJ9/, log, "a JWT must not survive")
    refute_match(/AKIAIOSFODNN7EXAMPLE/, log, "an AWS access key id must not survive")
    assert_match(/Cookie:/, log, "the header NAME should survive so the line stays readable")
  end

  test "redacts a bare JWT with no label at all" do
    raw = "web-1\n---\nrejected token eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJhZG1pbiJ9.QWxhZGRpbjpvcGVuc2VzYW1l here"
    log = tool(output: raw).call("app_name" => "Logged").value[:log]

    refute_match(/eyJhbGciOiJIUzI1NiJ9/, log)
    assert_match(/rejected token/, log)
  end

  test "leaves ordinary log lines untouched" do
    raw = "web-1\n---\nCompleted 200 OK in 4ms (Views: 1.2ms | ActiveRecord: 0.8ms)\nStarted GET \"/orgs/acme/folders?page=2\""
    res = tool(output: raw).call("app_name" => "Logged")

    assert_match(/ActiveRecord: 0\.8ms/, res.value[:log])
    assert_match(/page=2/, res.value[:log])
    refute res.value[:redacted], "a clean log must not be reported as redacted"
  end
end
