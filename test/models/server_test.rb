require "test_helper"

class ServerTest < ActiveSupport::TestCase
  test "display_status is pending until the server has actually been seen" do
    server = Server.new(name: "ssd-node", status: "online", last_seen_at: nil)
    assert_equal "pending", server.display_status, "never-seen server should not read online"
    refute server.ever_seen?
  end

  test "display_status reflects the real status once seen" do
    server = Server.new(name: "edge", status: "online", last_seen_at: Time.current)
    assert_equal "online", server.display_status
    assert server.ever_seen?

    server.status = "degraded"
    assert_equal "degraded", server.display_status
  end
end

# The reboot transition state: a Conductor-initiated reboot shows "rebooting" and
# opens a grace window, so expected unreachability isn't a false offline alert.
class ServerRebootStateTest < ActiveSupport::TestCase
  include ActionMailer::TestHelper

  setup do
    user = User.create!(email: "rebootstate@example.com")
    @org = Organization.create_for(user, name: "Acme")
    @server = @org.servers.create!(name: "box", status: "online", ip_address: "10.0.0.9", last_seen_at: Time.current)
  end

  test "mark_rebooting! sets the transitional status + grace window" do
    @server.mark_rebooting!
    assert_equal "rebooting", @server.status
    assert @server.rebooting_grace?
  end

  test "mark_offline! is a no-op with NO alert within the reboot grace window" do
    @server.mark_rebooting!
    assert_no_enqueued_emails { @server.mark_offline! }
    assert_equal "rebooting", @server.reload.status, "an intentional reboot must not flip to offline"
  end

  test "mark_offline! marks offline once past the grace window" do
    @server.update_columns(status: "rebooting", rebooting_at: 20.minutes.ago)
    @server.mark_offline!
    assert_equal "offline", @server.status
  end

  test "a successful metrics poll clears the reboot window back to online" do
    @server.mark_rebooting!
    @server.update_metrics!(cpu_percent: 1, memory_used_mb: 10, memory_total_mb: 100,
                            disk_percent: 5, uptime_seconds: 60, load_average: 0.1)
    assert_equal "online", @server.status
    assert_nil @server.rebooting_at
  end

  # Root is for provisioning only; every app-level operation runs as the deploy
  # user. The column already defaults to "deploy", but a row with a blank user
  # used to fall back to ROOT — silent privilege escalation for any server
  # registered without an explicit user. The only caller that legitimately needs
  # root (HardenServer, on a box where the deploy user does not exist yet) passes
  # `user: "root"` explicitly, so nothing depends on the implicit fallback.
  test "a blank ssh_user falls back to deploy, never root" do
    @server.update!(ssh_user: nil)
    assert_equal "deploy", @server.ssh_user_or_default

    @server.update!(ssh_user: "")
    assert_equal "deploy", @server.ssh_user_or_default
  end

  test "an explicitly configured ssh_user is still honoured, including root for provisioning" do
    @server.update!(ssh_user: "root")
    assert_equal "root", @server.ssh_user_or_default, "provisioning must still be able to ask for root explicitly"

    @server.update!(ssh_user: "ubuntu")
    assert_equal "ubuntu", @server.ssh_user_or_default
  end
end
