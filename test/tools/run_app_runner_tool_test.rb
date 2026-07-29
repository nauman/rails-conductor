require "test_helper"

class RunAppRunnerToolTest < ActiveSupport::TestCase
  setup do
    @org = Organization.create_for(User.create!(email: "runner@example.com"), name: "Acme")
    key = SshKey.create!(name: "k", private_key: valid_private_key, organization: @org)
    @server = @org.servers.create!(name: "s", status: "online", ip_address: "10.0.0.1", ssh_key: key)
  end

  def make_app(method: "kamal")
    @org.apps.create!(name: "web-#{method}", slug: "web-#{method}", server: @server,
                      deploy_method: method, repository_url: "https://example.com/r.git")
  end

  def tool = RunAppRunnerTool.new(user: nil)

  # A RemoteRailsRunner double whose run/run_task return a fixed Result.
  def runner_double(output:, exit_code:, ok: true)
    res = RemoteRailsRunner::Result.new(ok: ok, output: output, exit_code: exit_code)
    Object.new.tap do |o|
      o.define_singleton_method(:run) { |_| res }
      o.define_singleton_method(:run_task) { |_| res }
    end
  end

  test "action runner dispatches to RunAppRunnerTool" do
    assert_equal RunAppRunnerTool, ConductorAppTool::ACTIONS["runner"]
  end

  test "unknown app is a clean failure" do
    res = tool.call("app_id" => 0, "ruby" => "puts 1")
    assert res.failure?
    assert_match(/not found/i, res.error)
  end

  test "rejects a native app (no container to exec into)" do
    app = make_app(method: "native")
    res = tool.call("app_id" => app.id, "ruby" => "puts 1")
    assert res.failure?
    assert_match(/kamal or docker/i, res.error)
  end

  test "rejects passing both ruby and task" do
    app = make_app
    res = tool.call("app_id" => app.id, "ruby" => "puts 1", "task" => "db:migrate:status")
    assert res.failure?
    assert_match(/either/i, res.error)
  end

  test "rejects passing neither ruby nor task" do
    app = make_app
    res = tool.call("app_id" => app.id)
    assert res.failure?
  end

  test "rejects a task name with shell metacharacters" do
    app = make_app
    res = tool.call("app_id" => app.id, "task" => "db:migrate; rm -rf /")
    assert res.failure?
    assert_match(/invalid task/i, res.error)
  end

  test "runs ruby in the container and returns the output" do
    app = make_app
    RemoteRailsRunner.stub(:new, ->(*) { runner_double(output: "42\n", exit_code: 0) }) do
      res = tool.call("app_id" => app.id, "ruby" => "puts 6*7")
      assert res.success?, res.error
      assert_equal "ruby", res.value[:kind]
      assert res.value[:ok]
      assert_equal "42\n", res.value[:output]
    end
  end

  test "runs a rake/rails task in the container" do
    app = make_app
    RemoteRailsRunner.stub(:new, ->(*) { runner_double(output: "up\n", exit_code: 0) }) do
      res = tool.call("app_id" => app.id, "task" => "db:migrate:status")
      assert res.success?, res.error
      assert_equal "task", res.value[:kind]
      assert_equal "db:migrate:status", res.value[:ran]
    end
  end

  test "reports no running container distinctly (not a generic success)" do
    app = make_app
    RemoteRailsRunner.stub(:new, ->(*) { runner_double(output: "NO_CONTAINER (service: web-kamal)", exit_code: 3, ok: false) }) do
      res = tool.call("app_id" => app.id, "ruby" => "puts 1")
      assert res.success?, "the tool call itself succeeds — the container state is data"
      assert res.value[:no_container]
      refute res.value[:ok]
      assert_match(/no running container/i, res.value[:message])
    end
  end
end
