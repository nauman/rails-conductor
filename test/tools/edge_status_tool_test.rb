require "test_helper"

class EdgeStatusToolTest < ActiveSupport::TestCase
  test "read-only edge inspection delegates to EdgeOperations" do
    user = User.create!(email: "edge-read@example.com", admin: true)
    org = Organization.create_for(user, name: "Edge Read")
    app = org.apps.create!(name: "Read App", slug: "read-app", domain: "read.example.com")
    fake = Object.new
    fake.define_singleton_method(:call) { |operation, message: nil| { operation: operation, message: message } }

    result = EdgeStatusTool.new(user: user, operations_factory: ->(_app) { fake }).call("app_id" => app.id)

    assert result.success?, result.error
    assert_equal :inspect, result.value[:operation]
    assert_equal "Read App", result.value[:app]
  end
end
