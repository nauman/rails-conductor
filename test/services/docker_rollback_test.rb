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
      return { success: true, output: "livecid777", stderr: "" } if cmd.include?("label=service=")
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

  # After a zero-downtime deploy the live container is app-<id>-r<rev>-<sha>;
  # stopping only the legacy name would leave it running alongside the rollback.
  test "stops the container that is ACTUALLY serving, resolved by label" do
    ssh = FakeSsh.new
    DockerRollback.new(@app, @deployment, ssh: ssh).rollback!("abc1234")

    assert ssh.commands.any? { |c| c.include?("label=service=app-#{@app.id}") },
           "must resolve the live container by label"
    assert ssh.commands.any? { |c| c.include?("docker stop livecid777") },
           "must stop the live release container, not just the legacy name"
  end

  test "a caddy edge is repointed too — it pointed at the container we removed" do
    @app.server.update!(edge_type: "caddy")
    published = []
    fake_edge = Object.new
    fake_edge.define_singleton_method(:publish) { |**kw| published << kw; { route_id: "r1" } }

    Edge.stub(:for, ->(*, **) { fake_edge }) do
      DockerRollback.new(@app, @deployment, ssh: FakeSsh.new).rollback!("abc1234")
    end

    assert_equal 1, published.size, "a caddy edge must follow the rollback"
    assert_equal "127.0.0.1:3000", published.first[:upstream]
  end

  test "a caddy rollback publishes the host port to the Rails runtime port" do
    @app.server.update!(edge_type: "caddy")
    @app.update!(port: 9080)
    published = []
    fake_edge = Object.new
    fake_edge.define_singleton_method(:publish) { |**kw| published << kw; { route_id: "r1" } }
    ssh = FakeSsh.new

    Edge.stub(:for, ->(*, **) { fake_edge }) do
      DockerRollback.new(@app, @deployment, ssh: ssh).rollback!("abc1234")
    end

    run = ssh.commands.find { |c| c.start_with?("docker run") }
    assert_includes run, "-p 9080:3000"
    assert_includes run, "-e PORT=3000"
    assert_equal "127.0.0.1:9080", published.first[:upstream]
  end

  test "a container that exits immediately fails the rollback" do
    ssh = FakeSsh.new(container: "")

    assert_not DockerRollback.new(@app, @deployment, ssh: ssh).rollback!("abc1234")
    assert_match(/exited immediately|did not start/i, @deployment.reload.log.to_s)
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
