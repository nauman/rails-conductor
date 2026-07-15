require "test_helper"

class ApplicationCable::ConnectionTest < ActionCable::Connection::TestCase
  test "an unauthenticated websocket connection is rejected" do
    assert_reject_connection { connect }
  end
end
