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

  # Docker apps are label-resolved too now: a zero-downtime deploy names the
  # container app-<id>-r<rev>-<sha>, which the fixed name never matches.
  test "a docker app resolves its container by label, falling back to the fixed name" do
    docker_app = App.new(name: "Dock", slug: "dock", deploy_method: "docker")
    cmd = RemoteRailsRunner.new(docker_app, ssh: Object.new).command("puts 1")
    assert_includes cmd, "label=service="
    assert_includes cmd, "name=^/conductor-dock$"
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

  # The regression this pair exists to prevent: routing every kamal app through the
  # kamal harness WITHOUT asking whether it can answer. The deployed container holds
  # no kamal checkout, so each call came back ok:false with empty output — while the
  # docker path beside it worked — and that silence reached the whole fleet.
  class FakeOps
    Res = Struct.new(:ok, :output, :error, keyword_init: true) { def ok? = ok }

    def initialize(available) = @available = available
    def available? = @available
    def unavailable_reason = @available ? nil : "no checkout"
    def exec(_command) = Res.new(ok: true, output: "ran via kamal")
  end

  class RecordingSsh
    attr_reader :command

    def execute_with_status(command)
      @command = command
      { success: true, output: "ran via docker", exit_code: 0 }
    end
  end

  test "falls back to the docker path when the kamal harness cannot answer" do
    app = App.new(name: "MyApp", slug: "myapp", deploy_method: "kamal", server: Server.new(name: "box", ip_address: "203.0.113.10"))
    ssh = RecordingSsh.new

    KamalOps.stub(:new, FakeOps.new(false)) do
      result = RemoteRailsRunner.new(app, ssh: ssh).run("puts 1")

      assert result.ok?
      assert_equal "ran via docker", result.output
      assert_includes ssh.command, "docker exec"
    end
  end

  test "uses the kamal harness when it can answer" do
    app = App.new(name: "MyApp", slug: "myapp", deploy_method: "kamal", server: Server.new(name: "box", ip_address: "203.0.113.10"))
    ssh = RecordingSsh.new

    KamalOps.stub(:new, FakeOps.new(true)) do
      # A TASK, not arbitrary Ruby. This test previously asserted that `run` used
      # kamal — which pinned the defect: a piped script cannot survive `kamal app
      # exec`, because the pipeline is evaluated on the host. The harness is still
      # the right home for a bare task, so that is what it now asserts.
      result = RemoteRailsRunner.new(app, ssh: ssh).run_task("db:migrate")

      assert_equal "ran via kamal", result.output
      assert_nil ssh.command, "the docker path must not also run"
    end
  end

  # P0 regression reported from the field: every runner call failed with
  # `bash: line 1: bin/rails: No such file or directory` (exit 127) after the app was
  # deployed. `kamal app exec` renders `docker exec <c> <cmd>` into a HOST shell, so a
  # pipeline splits there — echo runs in the container, bin/rails is looked for on the
  # host. Arbitrary Ruby must therefore never go through kamal.
  #
  # It presented as a regression because ELIGIBILITY changed, not the command: a
  # deploy creates the kamal checkout that makes KamalOps available, so apps moved
  # onto the broken path the first time they were deployed from this container.
  test "arbitrary Ruby never goes through kamal, because a pipeline cannot survive it" do
    app = App.new(name: "MyApp", slug: "myapp", deploy_method: "kamal",
                  server: Server.new(name: "box", ip_address: "203.0.113.10"))
    ssh = RecordingSsh.new

    # Available and eager — and still must not be used for a piped script.
    KamalOps.stub(:new, FakeOps.new(true)) do
      result = RemoteRailsRunner.new(app, ssh: ssh).run("puts 1")

      assert_equal "ran via docker", result.output
    end

    assert_includes ssh.command, "docker exec -i", "the script must arrive on the container's stdin"
    assert_includes ssh.command, "base64 -d | docker exec", "decode on the host, pipe INTO the container"
    refute_match(/docker exec[^|]*\| base64/, ssh.command,
      "a pipeline after docker exec would be evaluated on the host — the reported bug")
  end

  test "a bare rails task still uses kamal, where the live-release resolver earns its keep" do
    app = App.new(name: "MyApp", slug: "myapp", deploy_method: "kamal",
                  server: Server.new(name: "box", ip_address: "203.0.113.10"))
    ssh = RecordingSsh.new

    KamalOps.stub(:new, FakeOps.new(true)) do
      assert_equal "ran via kamal", RemoteRailsRunner.new(app, ssh: ssh).run_task("db:migrate").output
    end
    assert_nil ssh.command
  end
end
