require "test_helper"

# Rollback for docker apps — possible only because releases are now SHA-tagged
# and retained (ADR 0003).
class DockerRollbackTest < ActiveSupport::TestCase
  class FakeSsh
    attr_reader :commands

    # `present:` controls whether the target image is found on the host.
    def initialize(present: true, container: "newcid123", boot: true)
      @commands = []
      @present = present
      @container = container
      @boot = boot
    end

    def execute_with_status(cmd)
      @commands << cmd
      return { success: true, output: (@present ? "PRESENT" : ""), stderr: "" } if cmd.include?("image inspect")
      return { success: @boot, output: @boot ? "" : "", stderr: @boot ? "" : "boom" } if cmd.start_with?("docker run")
      return { success: true, output: @container, stderr: "" } if cmd.include?("docker ps -q")

      { success: true, output: "", stderr: "" }
    end
  end

  setup do
    @org = Organization.create!(name: "Acme")
    @server = @org.servers.create!(name: "box", status: "online", ip_address: "10.0.0.1",
                                   edge_type: "kamal_proxy")
    @app = @org.apps.create!(name: "Shop", slug: "shop", server: @server, deploy_method: "docker",
                             port: 3000, image_name: "shop", domain: "shop.example.com",
                             repository_url: "https://github.com/x/y.git")
    @deployment = @app.deployments.create!(status: "pending")
  end

  test "boots the previously-shipped tag without rebuilding" do
    ssh = FakeSsh.new

    assert DockerRollback.new(@app, @deployment, ssh: ssh).rollback!("abc1234")

    run = ssh.commands.find { |c| c.start_with?("docker run") }
    assert_includes run, "shop:abc1234"
    assert_not ssh.commands.any? { |c| c.include?("docker build") }, "rollback must not rebuild"
    assert_equal "succeeded", @deployment.reload.status
  end

  # The failure that would turn a bad release into an outage.
  test "refuses BEFORE stopping the container when the image is gone" do
    ssh = FakeSsh.new(present: false)

    assert_not DockerRollback.new(@app, @deployment, ssh: ssh).rollback!("longgone")

    assert_not ssh.commands.any? { |c| c.start_with?("docker stop") },
               "must not stop a working container it cannot replace"
    assert_equal "failed", @deployment.reload.status
    assert_match(/retained releases/i, @deployment.reload.log.to_s)
  end

  test "repoints a container-targeting edge at the rolled-back container" do
    ssh = FakeSsh.new

    DockerRollback.new(@app, @deployment, ssh: ssh).rollback!("abc1234")

    publish = ssh.commands.find { |c| c.include?("kamal-proxy deploy") }
    assert publish, "a rollback replaces the container, so the edge must follow"
    assert_includes publish, "newcid123:3000"
  end

  test "leaves a caddy edge alone" do
    @app.server.update!(edge_type: "caddy")
    ssh = FakeSsh.new

    DockerRollback.new(@app, @deployment, ssh: ssh).rollback!("abc1234")

    assert_not ssh.commands.any? { |c| c.include?("kamal-proxy") }
  end

  test "carries the same labels a deploy does, so ops tooling still finds it" do
    ssh = FakeSsh.new
    DockerRollback.new(@app, @deployment, ssh: ssh).rollback!("abc1234")

    run = ssh.commands.find { |c| c.start_with?("docker run") }
    assert_includes run, "--label service=app-#{@app.id}"
    assert_includes run, "--label conductor.release=abc1234"
  end

  test "a blank version fails rather than booting something arbitrary" do
    assert_not DockerRollback.new(@app, @deployment, ssh: FakeSsh.new).rollback!("")
    assert_equal "failed", @deployment.reload.status
  end

  test "the job routes docker apps to DockerRollback and native apps to a clear failure" do
    @app.update!(deploy_method: "native")
    RollbackAppJob.perform_now(@deployment.id, "abc1234")

    assert_equal "failed", @deployment.reload.status
    assert_match(/not supported for native/i, @deployment.reload.log.to_s)
  end
end
