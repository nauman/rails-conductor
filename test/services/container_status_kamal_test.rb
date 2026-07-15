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
    @app = @org.apps.create!(name: "Appone", slug: "appone", server: @server, deploy_method: "kamal",
                             status: "stopped", repository_url: "https://x/r.git")
  end

  # docker's `{{.CreatedAt}}` format, e.g. "2026-07-14 04:15:32 +0000 UTC".
  def docker_created(time) = time.strftime("%Y-%m-%d %H:%M:%S %z UTC")

  # One line of `docker ps --format '{{.Labels}}|{{.CreatedAt}}'` + the exit marker.
  def ps_line(created_time, service: "appone")
    "service=#{service},role=web,destination=|#{docker_created(created_time)}\n__RC__:0"
  end

  test "a docker permission/daemon error reads as unknown, not stopped" do
    ssh = FakeSsh.new(output: "permission denied while trying to connect to the Docker daemon socket at unix:///var/run/docker.sock\n__RC__:1")
    SshConnection.stub(:new, ssh) { ContainerStatus.new(@app).sync! }

    @app.reload
    assert_equal "unknown", @app.container_status, "docker being inaccessible must not look 'stopped'"
    assert @app.status_check_error.present?
    assert_match(/docker group/i, @app.status_check_error)
  end

  test "a running kamal container marks the app running and reconciles App.status" do
    ssh = FakeSsh.new(output: ps_line(Time.current))
    SshConnection.stub(:new, ssh) { ContainerStatus.new(@app).sync! }

    assert_equal "running", @app.reload.status
    assert_equal "running", @app.container_status
    assert_includes ssh.commands.first, "status=running"
    assert_includes ssh.commands.first, "{{.Labels}}"
  end

  test "detects a container whose service label differs from the slug (calm-page vs calmpage)" do
    @app.update!(slug: "calm-page")
    # Container is labelled service=calmpage, but the app's slug is calm-page.
    ssh = FakeSsh.new(output: ps_line(Time.current, service: "calmpage"))
    SshConnection.stub(:new, ssh) { ContainerStatus.new(@app).sync! }

    assert_equal "running", @app.reload.status, "must match the separator-stripped service name"
  end

  test "a running container with a FAILED latest deploy (older than the container's start) flags needs-attention" do
    @app.deployments.create!(status: "failed", completed_at: Time.current)
    # Container predates the failed deploy → we're still on the previous release.
    ssh = FakeSsh.new(output: ps_line(1.hour.ago))
    SshConnection.stub(:new, ssh) { ContainerStatus.new(@app).sync! }

    @app.reload
    assert_equal "running", @app.status, "container is up, so it's running…"
    assert @app.status_check_error.present?, "…but the failed last deploy must be surfaced"
    assert_match(/previous release/i, @app.status_check_error)
    assert @app.needs_attention?
  end

  test "a stale failed deploy older than the running container is NOT reported (self-deploy via CI case)" do
    # Failed deploy weeks ago, but the running container is fresh → a later
    # (out-of-band) deploy replaced it. Don't cry wolf.
    @app.deployments.create!(status: "failed", completed_at: 30.days.ago)
    ssh = FakeSsh.new(output: ps_line(Time.current))
    SshConnection.stub(:new, ssh) { ContainerStatus.new(@app).sync! }

    @app.reload
    assert_equal "running", @app.status
    assert_nil @app.status_check_error, "a container newer than the failed deploy is not 'serving the previous release'"
  end

  test "a running container with a succeeded latest deploy stays clean green" do
    @app.deployments.create!(status: "succeeded", completed_at: Time.current)
    ssh = FakeSsh.new(output: ps_line(Time.current))
    SshConnection.stub(:new, ssh) { ContainerStatus.new(@app).sync! }

    assert_nil @app.reload.status_check_error
  end

  test "no running kamal container marks the app stopped" do
    ssh = FakeSsh.new(output: "")
    SshConnection.stub(:new, ssh) { ContainerStatus.new(@app).sync! }

    assert_equal "stopped", @app.reload.status
    assert_equal "exited", @app.container_status
  end

  test "kamal apps are status-syncable" do
    assert @app.can_sync_status?
    assert_equal "appone", @app.kamal_service
  end
end
