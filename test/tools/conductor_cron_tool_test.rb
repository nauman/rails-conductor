require "test_helper"

class AppScheduledCommandTest < ActiveSupport::TestCase
  test "kamal: resolves the running container and runs the task" do
    cmd = App.new(name: "A", slug: "a", deploy_method: "kamal").scheduled_command("slack:sync")
    assert_includes cmd, "for s in a"
    assert_includes cmd, "docker exec"
    assert_includes cmd, "bin/rails slack:sync"
  end

  test "docker: execs the conductor-<slug> container" do
    assert_includes App.new(name: "A", slug: "a", deploy_method: "docker").scheduled_command("x:y"),
                    "docker exec conductor-a bin/rails x:y"
  end
end

class ConductorCronToolTest < ActiveSupport::TestCase
  # Fake CrontabClient recording install/remove instead of SSHing.
  class FakeCrontab
    attr_reader :calls
    def initialize(*) = @calls = []
    def upsert_job(**kw) = (@calls << [ :upsert, kw ]; true)
    def remove_job(**kw) = (@calls << [ :remove, kw ]; true)
  end

  setup do
    @user = User.create!(email: "cron-tool@example.com", admin: true)
    @org = Organization.create_for(@user, name: "Acme")
    key = SshKey.create!(name: "k", private_key: valid_private_key, organization: @org)
    @server = @org.servers.create!(name: "box", status: "online", ip_address: "10.0.0.5", ssh_key: key)
    @app = @org.apps.create!(name: "Slackapp", slug: "slackapp", server: @server, deploy_method: "kamal", status: "running")
    @fake = FakeCrontab.new
  end

  def with_fake_crontab(&blk) = CrontabClient.stub(:new, ->(*) { @fake }, &blk)

  test "schedule creates + installs a cron for an app rails task" do
    with_fake_crontab do
      res = ConductorCronTool.new(user: @user).call(
        "action" => "schedule", "app_id" => @app.id, "name" => "Slack sync",
        "schedule" => "0 * * * *", "task" => "slack:sync"
      )
      assert res.success?, res.error
      assert_equal "0 * * * *", res.value[:cron]
      assert_includes res.value[:command], "bin/rails slack:sync"
      assert_equal @server.name, res.value[:server]
      assert @fake.calls.any? { |verb,| verb == :upsert }, "should install into the crontab"
      assert_equal 1, CronJob.where(server: @server).count
      # structured app scope (not inferred from the command)
      assert_equal "app", res.value[:scope]
      assert_equal "Slackapp", res.value[:app]
      assert_equal "slack:sync", res.value[:task]
      assert_equal @app.id, CronJob.last.app_id
    end
  end

  test "a server-scoped raw-command cron has scope=server and no app" do
    with_fake_crontab do
      res = ConductorCronTool.new(user: @user).call(
        "action" => "schedule", "server_id" => @server.id, "name" => "backup",
        "schedule" => "0 3 * * *", "command" => "/usr/local/bin/backup.sh"
      )
      assert res.success?, res.error
      assert_equal "server", res.value[:scope]
      assert_nil res.value[:app]
      assert_nil CronJob.last.app_id
    end
  end

  test "update changes an app job's task and regenerates the container-exec command" do
    with_fake_crontab do
      created = ConductorCronTool.new(user: @user).call(
        "action" => "schedule", "app_id" => @app.id, "name" => "Slack sync",
        "schedule" => "0 * * * *", "task" => "slack:sync"
      )
      res = ConductorCronTool.new(user: @user).call(
        "action" => "update", "cron_job_id" => created.value[:id], "task" => "slack:prune", "schedule" => "30 4 * * *"
      )
      assert res.success?, res.error
      assert_equal "slack:prune", res.value[:task]
      assert_includes res.value[:command], "bin/rails slack:prune"
      assert_equal "30 4 * * *", res.value[:cron]
    end
  end

  test "update rejects a task on a server-scoped cron (and command on an app job)" do
    with_fake_crontab do
      srv = ConductorCronTool.new(user: @user).call(
        "action" => "schedule", "server_id" => @server.id, "name" => "b", "schedule" => "0 3 * * *", "command" => "x"
      )
      bad = ConductorCronTool.new(user: @user).call(
        "action" => "update", "cron_job_id" => srv.value[:id], "task" => "slack:sync"
      )
      assert bad.failure?
      assert_match(/server cron/i, bad.error)
    end
  end

  test "schedule rejects an unsafe task name (no shell injection into cron)" do
    with_fake_crontab do
      res = ConductorCronTool.new(user: @user).call(
        "action" => "schedule", "app_id" => @app.id, "name" => "x", "schedule" => "0 * * * *", "task" => "slack:sync; rm -rf /"
      )
      refute res.success?
      assert_match(/Invalid task/, res.error)
      assert_equal 0, CronJob.count
    end
  end

  test "schedule on a server with a raw command" do
    with_fake_crontab do
      res = ConductorCronTool.new(user: @user).call(
        "action" => "schedule", "server_id" => @server.id, "name" => "Cleanup", "schedule" => "0 3 * * *", "command" => "/usr/local/bin/cleanup.sh"
      )
      assert res.success?, res.error
      assert_equal "/usr/local/bin/cleanup.sh", res.value[:command]
    end
  end

  test "list returns managed jobs; remove uninstalls + deletes; set_enabled toggles" do
    with_fake_crontab do
      created = ConductorCronTool.new(user: @user).call(
        "action" => "schedule", "app_id" => @app.id, "name" => "Sync", "schedule" => "0 * * * *", "task" => "slack:sync"
      )
      id = created.value[:id]

      listed = ConductorCronTool.new(user: @user).call("action" => "list", "server_id" => @server.id)
      assert listed.success?
      assert_equal 1, listed.value[:cron_jobs].size

      dis = ConductorCronTool.new(user: @user).call("action" => "set_enabled", "cron_job_id" => id, "enabled" => false)
      assert dis.success?, dis.error
      refute dis.value[:enabled]

      rem = ConductorCronTool.new(user: @user).call("action" => "remove", "cron_job_id" => id)
      assert rem.success?, rem.error
      assert rem.value[:removed]
      assert_nil CronJob.find_by(id: id)
      assert @fake.calls.any? { |verb,| verb == :remove }
    end
  end

  test "remove reports an unknown job" do
    res = ConductorCronTool.new(user: @user).call("action" => "remove", "cron_job_id" => 999_999)
    refute res.success?
    assert_includes res.error, "not found"
  end
end
