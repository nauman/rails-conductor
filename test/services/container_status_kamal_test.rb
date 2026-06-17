require "test_helper"

class ContainerStatusKamalTest < ActiveSupport::TestCase
  # Minimal SSH stub matching SshConnection's interface used by ContainerStatus.
  class FakeSsh
    attr_reader :commands, :error
    def initialize(output:, success: true, error: nil)
      @output = output; @success = success; @error = error; @commands = []
    end
    def execute(cmd) = (@commands << cmd; @output)
    def success? = @success
  end

  setup do
    user = User.create!(email: "cs@example.com")
    @org = Organization.create_for(user, name: "Acme")
    key = SshKey.create!(name: "k", private_key: valid_private_key, organization: @org)
    @server = @org.servers.create!(name: "fleet", status: "online", ip_address: "10.0.0.9", ssh_key: key)
    @app = @org.apps.create!(name: "Kuickr", slug: "kuickr", server: @server, deploy_method: "kamal",
                             status: "stopped", repository_url: "https://x/r.git")
  end

  test "a running kamal container marks the app running and reconciles App.status" do
    ssh = FakeSsh.new(output: "kuickr-web-abc123\n")
    SshConnection.stub(:new, ssh) { ContainerStatus.new(@app).sync! }

    assert_equal "running", @app.reload.status
    assert_equal "running", @app.container_status
    assert_includes ssh.commands.first, "label=service=kuickr"
    assert_includes ssh.commands.first, "status=running"
  end

  test "no running kamal container marks the app stopped" do
    ssh = FakeSsh.new(output: "")
    SshConnection.stub(:new, ssh) { ContainerStatus.new(@app).sync! }

    assert_equal "stopped", @app.reload.status
    assert_equal "exited", @app.container_status
  end

  test "kamal apps are status-syncable" do
    assert @app.can_sync_status?
    assert_equal "kuickr", @app.kamal_service
  end
end
