require "test_helper"
require "base64"

class RemoteRailsRunnerTest < ActiveSupport::TestCase
  setup do
    @app = App.new(name: "MyApp", slug: "myapp", deploy_method: "kamal")
    @runner = RemoteRailsRunner.new(@app, ssh: Object.new)
  end

  test "command resolves the container by service label and base64-pipes the script into rails runner" do
    cmd = @runner.command("puts 1")
    assert_includes cmd, "for s in myapp"
    assert_includes cmd, "label=service=$s"
    assert_includes cmd, Base64.strict_encode64("puts 1")
    assert_includes cmd, "base64 -d | docker exec -i"
    assert_includes cmd, "bin/rails runner -"
    assert_includes cmd, "NO_CONTAINER"
  end

  test "a docker app resolves its container by conductor-<slug> name, not a service label" do
    docker_app = App.new(name: "Dock", slug: "dock", deploy_method: "docker")
    cmd = RemoteRailsRunner.new(docker_app, ssh: Object.new).command("puts 1")
    assert_includes cmd, "name=^/conductor-dock$"
    refute_includes cmd, "label=service="
    assert_includes cmd, "bin/rails runner -"
  end

  test "task_command runs a bare rails task in the resolved container" do
    cmd = @runner.task_command("db:migrate:status")
    assert_includes cmd, "for s in myapp"
    assert_includes cmd, "docker exec \"$cid\" bin/rails db:migrate:status"
  end

  test "Result#payload parses the JSON printed after the marker" do
    out = "some noise\n#{RemoteRailsRunner::MARKER}#{{ 'total_blobs' => 5 }.to_json}\n"
    res = RemoteRailsRunner::Result.new(ok: true, output: out, exit_code: 0)
    assert_equal({ "total_blobs" => 5 }, res.payload)
  end

  test "Result#payload is nil when the marker is absent" do
    res = RemoteRailsRunner::Result.new(ok: false, output: "NO_CONTAINER (service: myapp)", exit_code: 3)
    assert_nil res.payload
  end
end
