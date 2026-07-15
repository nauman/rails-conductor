require "test_helper"

class ContainerStatusDockerTest < ActiveSupport::TestCase
  class FakeSsh
    attr_reader :error
    def initialize(output:, success: true, error: nil)
      @output = output; @success = success; @error = error
    end
    def execute(_cmd) = @output
    def success? = @success
  end

  setup do
    user = User.create!(email: "csd@example.com")
    @org = Organization.create_for(user, name: "Acme")
    key = SshKey.create!(name: "k", private_key: valid_private_key, organization: @org)
    @server = @org.servers.create!(name: "fleet", status: "online", ip_address: "10.0.0.9", ssh_key: key)
    @app = @org.apps.create!(name: "Dock", slug: "dock", server: @server, deploy_method: "docker",
                             status: "stopped", repository_url: "https://x/r.git")
  end

  test "a deliberately-stopped app with no container is a clean stopped state, not a sync failure" do
    ssh = FakeSsh.new(output: "") # SSH worked, docker inspect found nothing
    SshConnection.stub(:new, ssh) { ContainerStatus.new(@app).sync! }

    @app.reload
    assert_equal "exited", @app.container_status
    assert_nil @app.status_check_error, "a stopped app's missing container must not read as 'Sync failed'"
    assert_not @app.needs_attention?
  end

  test "a running app with a missing container IS a real failure" do
    @app.update!(status: "running")
    ssh = FakeSsh.new(output: "Error: No such object: conductor-dock\n__RC__:1")
    SshConnection.stub(:new, ssh) { ContainerStatus.new(@app).sync! }

    @app.reload
    assert_equal "unknown", @app.container_status
    assert @app.status_check_error.present?, "an app that should be running but has no container is a real problem"
  end

  test "a docker daemon/permission error is unknown+error, even for a stopped app" do
    ssh = FakeSsh.new(output: "Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?\n__RC__:1")
    SshConnection.stub(:new, ssh) { ContainerStatus.new(@app).sync! }

    @app.reload
    assert_equal "unknown", @app.container_status, "a down daemon must not read as a clean 'stopped'"
    assert @app.status_check_error.present?
  end
end
