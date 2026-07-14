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
