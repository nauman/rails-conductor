require "test_helper"

class McpCallTest < ActiveSupport::TestCase
  test "record persists a successful call with serialized result" do
    call = McpCall.record(
      tool_name: "fleet_status", arguments: { "verbose" => true },
      result: Result.ok({ "servers" => 2 }), duration_ms: 12
    )

    assert call.persisted?
    assert_equal "success", call.status
    assert call.success?
    assert_equal({ "verbose" => true }, call.arguments)
    assert_equal({ "servers" => 2 }, JSON.parse(call.result))
    assert_nil call.error
    assert_equal 12, call.duration_ms
  end

  test "record persists a failed call with the error message" do
    call = McpCall.record(
      tool_name: "deploy_app", arguments: {},
      result: Result.fail("App not found"), duration_ms: 3
    )

    assert_equal "failed", call.status
    refute call.success?
    assert_equal "App not found", call.error
    assert_nil call.result
  end

  test "record stores the organization when provided" do
    org = Organization.create!(name: "Acme")
    call = McpCall.record(
      tool_name: "deploy_app", arguments: {},
      result: Result.ok({ "app" => "x" }), duration_ms: 4, organization: org
    )

    assert_equal org, call.organization
  end

  test "record leaves organization nil when not provided" do
    call = McpCall.record(
      tool_name: "fleet_status", arguments: {},
      result: Result.ok([]), duration_ms: 1
    )

    assert_nil call.organization
  end

  test "redacts secret-bearing argument keys before persisting" do
    call = McpCall.record(
      tool_name: "register_database_cluster",
      arguments: { "name" => "shared", "admin_password" => "s3cret", "value" => "envval", "api_key" => "ak_1" },
      result: Result.ok({ "ok" => true }), duration_ms: 1
    )

    assert_equal "shared", call.arguments["name"]
    assert_equal "[REDACTED]", call.arguments["admin_password"]
    assert_equal "[REDACTED]", call.arguments["value"]
    assert_equal "[REDACTED]", call.arguments["api_key"]
  end

  test "redacts secrets in the stored result (e.g. a returned database_url)" do
    call = McpCall.record(
      tool_name: "provision_database", arguments: {},
      result: Result.ok({ "name" => "slim_thought_production", "database_url" => "postgres://u:p@h/db" }),
      duration_ms: 1
    )

    stored = JSON.parse(call.result)
    assert_equal "slim_thought_production", stored["name"]
    assert_equal "[REDACTED]", stored["database_url"]
  end

  test "validates status inclusion" do
    refute McpCall.new(tool_name: "x", status: "bogus").valid?
  end

  test "validates tool_name presence" do
    refute McpCall.new(status: "success").valid?
  end
end
