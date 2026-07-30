require "test_helper"

# The MCP surface authorizes per ACTION, not per tool, because destructive
# actions live inside tools an editor legitimately needs (conductor_app carries
# `deploy` next to `retire`, `transfer`, and `runner`).
class ToolAuthorizationTest < ActiveSupport::TestCase
  setup do
    @org = Organization.create!(name: "Acme")
    @owner = User.create!(email: "owner@example.com")
    @editor = User.create!(email: "editor@example.com")
    @member = User.create!(email: "member@example.com")
    @org.add_member(@owner, role: :owner)
    @org.add_member(@editor, role: :editor)
    @org.add_member(@member, role: :member)

    Current.organization = @org
    Current.read_only = false
  end

  teardown do
    Current.organization = nil
    Current.read_only = false
  end

  def call(tool, input, user:)
    ToolRegistry.call(tool, input, user: user)
  end

  test "an editor is refused every owner-only action, by capability" do
    {
      [ "conductor_app", "retire" ] => "destroy",
      [ "conductor_app", "transfer" ] => "destroy",
      [ "conductor_app", "runner" ] => "execute",
      [ "conductor_app", "convert_database" ] => "credentials",
      [ "conductor_server", "remove" ] => "destroy",
      [ "conductor_server", "run_script" ] => "execute",
      [ "conductor_server", "add_ssh_key" ] => "credentials",
      [ "conductor_domain", "delete_dns" ] => "destroy",
      [ "conductor_github", "set_token" ] => "credentials",
      [ "conductor_cron", "schedule" ] => "execute"
    }.each do |(tool, action), capability|
      res = call(tool, { "action" => action }, user: @editor)

      assert_not res.success?, "editor must be refused #{tool}/#{action}"
      assert_match(/owner/i, res.error)
      assert_match(capability, res.error)
    end
  end

  test "an editor keeps the deploy path inside the same tool" do
    res = call("conductor_app", { "action" => "deploy" }, user: @editor)

    # It fails on missing params, NOT on authorization — the gate let it through.
    assert_no_match(/requires an organization owner/i, res.error.to_s)
  end

  test "a member is refused mutating actions even with a deploy token" do
    res = call("conductor_app", { "action" => "deploy" }, user: @member)

    assert_not res.success?
    assert_match(/owner or editor/i, res.error)
  end

  test "an owner passes the gate on owner-only actions" do
    res = call("conductor_app", { "action" => "runner" }, user: @owner)

    assert_no_match(/requires an organization owner/i, res.error.to_s)
  end

  test "field escalation: update is editor-safe until it flips seed_on_next_deploy" do
    ok = call("conductor_app", { "action" => "update", "notes" => "hi" }, user: @editor)
    assert_no_match(/requires an organization owner/i, ok.error.to_s)

    seeded = call("conductor_app", { "action" => "update", "seed_on_next_deploy" => true }, user: @editor)
    assert_not seeded.success?
    assert_match(/execute/, seeded.error)

    repoint = call("conductor_app", { "action" => "update", "repository_url" => "https://x/y" }, user: @editor)
    assert_not repoint.success?
    assert_match(/repository/, repoint.error)
  end

  test "a read-only token reaches read actions inside mutating tools" do
    Current.read_only = true

    refused = call("conductor_app", { "action" => "deploy" }, user: @owner)
    assert_match(/read-only/i, refused.error)

    allowed = call("conductor_app", { "action" => "transfer_plan" }, user: @owner)
    assert_no_match(/read-only/i, allowed.error.to_s)
  end
end
