require "test_helper"

class RefreshServerMetricsJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include ActionMailer::TestHelper

  METRICS = <<~OUTPUT.freeze
    CPU:4.2
    CORES:6
    MEM_USED:1024
    MEM_TOTAL:8192
    DISK:42
    UPTIME:3600
    LOAD:0.4
  OUTPUT

  class SequencedSsh
    attr_reader :error

    def initialize(outcomes)
      @outcomes = outcomes
    end

    def execute(*)
      case @outcomes.shift
      when :timeout
        @error = "Connection timed out: Net::SSH::ConnectionTimeout"
        nil
      when :success
        @error = nil
        METRICS
      else
        raise "No SSH outcome left for metrics probe"
      end
    end

    def success? = error.nil?
  end

  setup do
    user = User.create!(email: "metrics-alert@example.com", admin: true)
    org = Organization.create_for(user, name: "Metrics")
    key = SshKey.create!(name: "metrics-key", private_key: valid_private_key, organization: org)
    @server = org.servers.create!(name: "metrics-box", status: "online", ip_address: "10.0.0.8",
                                  ssh_key: key, last_seen_at: Time.current)
  end

  test "a connection timeout is retried before changing server state" do
    with_ssh_outcomes(:timeout, :success) do
      assert_no_enqueued_emails { perform_metrics_poll }
    end

    assert_equal "online", @server.reload.status
  end

  test "one failed polling cycle degrades the server without an offline email" do
    with_ssh_outcomes(:timeout, :timeout) do
      assert_no_enqueued_emails { perform_metrics_poll }
    end

    assert_equal "degraded", @server.reload.status
  end

  test "two consecutive failed polling cycles mark the server offline once" do
    with_ssh_outcomes(:timeout, :timeout, :timeout, :timeout) do
      assert_no_enqueued_emails { perform_metrics_poll }
      assert_equal "degraded", @server.reload.status

      assert_enqueued_email_with(AlertMailer, :server_offline, args: [ @server ]) do
        perform_metrics_poll
      end
    end

    assert_equal "offline", @server.reload.status
  end

  test "an already degraded status is not mistaken for a prior failed poll" do
    @server.update!(status: "degraded")

    with_ssh_outcomes(:timeout, :timeout) do
      assert_no_enqueued_emails { perform_metrics_poll }
    end

    assert_equal "degraded", @server.reload.status
  end

  test "a successful polling cycle resets a degraded server to online" do
    @server.update!(status: "degraded")

    with_ssh_outcomes(:success) { perform_metrics_poll }

    assert_equal "online", @server.reload.status
  end

  test "metrics and app status probes share one concurrency key per server" do
    app = @server.organization.apps.create!(name: "probe-app", slug: "probe-app", server: @server,
                                            deploy_method: "docker")

    metrics_key = RefreshServerMetricsJob.new(@server.id).concurrency_key
    status_key = SyncContainerStatusJob.new(app.id).concurrency_key

    assert_equal metrics_key, status_key
    assert_match(/#{@server.id}/, metrics_key)
  end

  private

  def perform_metrics_poll
    perform_enqueued_jobs(only: RefreshServerMetricsJob) do
      RefreshServerMetricsJob.perform_later(@server.id)
    end
  end

  def with_ssh_outcomes(*outcomes)
    sequence = outcomes.dup
    SshConnection.stub(:new, ->(*) { SequencedSsh.new(sequence) }) { yield }
    assert_empty sequence, "the poll did not consume every expected SSH attempt"
  end
end
