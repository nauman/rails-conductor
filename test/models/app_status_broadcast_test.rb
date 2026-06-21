require "test_helper"
require "turbo/broadcastable/test_helper"

# App status badges update live over Turbo Streams — when a status-relevant field
# changes (deploy, status sync, etc.), the badge is replaced on any open page with
# no polling or manual refresh.
class AppStatusBroadcastTest < ActiveSupport::TestCase
  include Turbo::Broadcastable::TestHelper

  setup do
    @org = Organization.create!(name: "Acme")
    @app = @org.apps.create!(name: "Kuickr", slug: "kuickr", deploy_method: "kamal", status: "stopped")
  end

  test "changing status broadcasts a badge replace to the app stream" do
    assert_turbo_stream_broadcasts(@app, count: 1) do
      @app.update!(status: "running")
    end
  end

  test "changing container_status broadcasts" do
    assert_turbo_stream_broadcasts(@app, count: 1) { @app.update!(container_status: "running") }
  end

  test "changing status_check_error broadcasts" do
    assert_turbo_stream_broadcasts(@app, count: 1) { @app.update!(status_check_error: "boom") }
  end

  test "changing an unrelated field does NOT broadcast" do
    assert_no_turbo_stream_broadcasts(@app) do
      @app.update!(notes: "just a note")
    end
  end
end
