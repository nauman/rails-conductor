require "test_helper"

class RebootRecoveryJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    user = User.create!(email: "recover@example.com")
    @org = Organization.create_for(user, name: "Acme")
    key = SshKey.create!(name: "k", private_key: valid_private_key, organization: @org)
    @server = @org.servers.create!(name: "box", status: "rebooting", ip_address: "10.0.0.7",
                                   ssh_key: key, rebooting_at: Time.current)
  end

  def kamal_app(container_status:, status: "running")
    app = @org.apps.create!(name: "web-#{container_status}", slug: "web-#{container_status}",
                            server: @server, deploy_method: "kamal",
                            repository_url: "https://example.com/r.git",
                            status: status, container_status: container_status,
                            last_status_check_at: Time.current)
    app
  end

  # A fake SSH that reports reachability via #test.
  def ssh_double(reachable)
    Object.new.tap { |o| o.define_singleton_method(:test) { reachable } }
  end

  # A fake ServerMetrics whose fetch_and_update! marks the box online with a
  # freshly-booted uptime (so recovery proceeds instead of waiting to settle).
  def metrics_double(server, uptime:)
    Object.new.tap do |o|
      o.define_singleton_method(:fetch_and_update!) do
        server.update_metrics!(cpu_percent: 1, memory_used_mb: 10, memory_total_mb: 100,
                               disk_percent: 5, uptime_seconds: uptime, load_average: 0.1)
        true
      end
    end
  end

  # A no-op ContainerStatus: recovery calls sync!, but the test pins container
  # state directly, so sync! must not clobber it.
  def cs_noop
    Object.new.tap { |o| o.define_singleton_method(:sync!) { true } }
  end

  test "when the box is still unreachable it re-enqueues the next poll" do
    SshConnection.stub(:new, ->(*) { ssh_double(false) }) do
      assert_enqueued_with(job: RebootRecoveryJob, args: [ @server.id, 2 ]) do
        RebootRecoveryJob.new.perform(@server.id, 1)
      end
    end
    assert_nil @server.reload.last_recovery_at, "no recovery report until the box is verified"
  end

  test "after the max attempts it records a 'did not return' report and stops polling" do
    SshConnection.stub(:new, ->(*) { ssh_double(false) }) do
      assert_no_enqueued_jobs do
        RebootRecoveryJob.new.perform(@server.id, RebootRecoveryJob::MAX_ATTEMPTS)
      end
    end
    assert_match(/did not answer/i, @server.reload.last_recovery_report)
  end

  test "a reachable box with a healthy app records a clean report and restarts nothing" do
    kamal_app(container_status: "running")
    SshConnection.stub(:new, ->(*) { ssh_double(true) }) do
      ServerMetrics.stub(:new, ->(s) { metrics_double(s, uptime: 60) }) do
        ContainerStatus.stub(:new, ->(*) { cs_noop }) do
          RestartAppJob.stub(:perform_now, ->(*) { flunk "healthy app must not be restarted" }) do
            RebootRecoveryJob.new.perform(@server.id, 1)
          end
        end
      end
    end
    report = @server.reload.last_recovery_report
    assert_match(/1 app/i, report)
    assert_equal "online", @server.status, "a verified box is back online"
  end

  test "a reachable box restarts an exited app and reports the remediation" do
    app = kamal_app(container_status: "exited") # meant to run, but down → needs attention
    restarted = []
    SshConnection.stub(:new, ->(*) { ssh_double(true) }) do
      ServerMetrics.stub(:new, ->(s) { metrics_double(s, uptime: 60) }) do
        ContainerStatus.stub(:new, ->(*) { cs_noop }) do
          restart = ->(id) do
            restarted << id
            App.find(id).update!(status: "running", container_status: "running")
          end
          RestartAppJob.stub(:perform_now, restart) do
            RebootRecoveryJob.new.perform(@server.id, 1)
          end
        end
      end
    end
    assert_equal [ app.id ], restarted, "the exited app should have been restarted"
    assert_match(/restart/i, @server.reload.last_recovery_report)
  end
end
