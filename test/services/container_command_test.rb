require "test_helper"

# A Kamal app's container is <service>-<role>-<version>, so a fixed container
# name never matches it. The UI's Stop button used a fixed name for every app
# and reported "App stopped." while the container kept running.
class ContainerCommandTest < ActiveSupport::TestCase
  setup do
    @org = Organization.create!(name: "Acme")
    @server = @org.servers.create!(name: "box", status: "online", ip_address: "10.0.0.1")
    @app = @org.apps.create!(name: "Shop", slug: "shop", server: @server,
                             deploy_method: "docker", repository_url: "https://github.com/x/y.git")
  end

  # A zero-downtime deploy runs the app as app-<id>-r<rev>-<sha>, so a fixed name
  # matches nothing and "succeeds" against no container.
  test "a docker app is found by its service label, with the fixed name as fallback" do
    cmd = ContainerCommand.stop(@app)

    assert_includes cmd, "for s in app-#{@app.id}", "the stable key must be the first candidate"
    assert_includes cmd, 'label=service=$s'
    assert_includes cmd, "name=^conductor-shop$", "legacy containers must still be reachable"
    assert_includes cmd, 'docker stop "$cid"'
    assert cmd.index("label=service=$s") < cmd.index("name=^conductor-shop$"),
           "the label must be tried before the legacy name"
  end

  test "the stable resource key is tried before any kamal service variant" do
    keys = ContainerCommand.stop(@app)[/for s in (.*?); do/, 1].split

    assert_equal "app-#{@app.id}", keys.first
  end

  test "a kamal app is located by its service label, never a fixed name" do
    @app.update!(deploy_method: "kamal")
    cmd = ContainerCommand.stop(@app)

    assert_includes cmd, "label=service="
    assert_includes cmd, "docker stop"
    assert_not_includes cmd, "docker stop conductor-shop",
                        "a fixed name would match nothing for a Kamal app"
  end

  test "a kamal lookup includes stopped containers so restart can reach them" do
    @app.update!(deploy_method: "kamal")

    assert_includes ContainerCommand.restart(@app), "docker ps -aq"
  end

  test "a kamal lookup reports NO_CONTAINER rather than silently doing nothing" do
    @app.update!(deploy_method: "kamal")

    assert_includes ContainerCommand.stop(@app), ContainerCommand::NO_CONTAINER
  end

  test "a native app is addressed through systemd" do
    @app.update!(deploy_method: "native")

    assert_equal "systemctl --user stop #{@app.service_name}", ContainerCommand.stop(@app)
    assert_equal "systemctl --user restart #{@app.service_name}", ContainerCommand.restart(@app)
  end

  test "shell metacharacters in the service name are escaped" do
    @app.update!(deploy_method: "kamal", slug: "shop")
    @app.stub(:kamal_service_candidates, [ "shop; rm -rf /" ]) do
      assert_includes ContainerCommand.stop(@app), "shop\\;\\ rm\\ -rf\\ /"
    end
  end
end
