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
      [ "conductor_cron", "schedule" ] => "execute",
      [ "conductor_app_config", "gen_deploy_key" ] => "credentials"
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

  # An action that opens SSH and writes rows is not a read, however it is named.
  test "SSH-touching server actions are not readable by a read-scoped token" do
    Current.read_only = true

    %w[test_connection audit].each do |action|
      res = call("conductor_server", { "action" => action }, user: @owner)
      assert_match(/read-only/i, res.error.to_s, "conductor_server/#{action} must not be read-only")
    end
  end

  test "a read-only token reaches read actions inside mutating tools" do
    Current.read_only = true

    refused = call("conductor_app", { "action" => "deploy" }, user: @owner)
    assert_match(/read-only/i, refused.error)

    allowed = call("conductor_app", { "action" => "transfer_plan" }, user: @owner)
    assert_no_match(/read-only/i, allowed.error.to_s)
  end

  # SC-009 Decision B. `runner` is owner-only because it executes arbitrary Ruby,
  # but a bare read-only task is a different thing wearing the same action name:
  # an editor who can deploy should be able to ask whether migrations are pending.
  test "an editor may run an allowlisted READ-ONLY task" do
    ReadOnlyRailsTasks::TASKS.each do |task|
      res = call("conductor_app", { "action" => "runner", "task" => task }, user: @editor)

      assert_no_match(/requires an organization owner/i, res.error.to_s,
                      "#{task} is read-only and should not need :execute")
    end
  end

  test "an editor is still refused a task that is NOT allowlisted" do
    res = call("conductor_app", { "action" => "runner", "task" => "db:migrate" }, user: @editor)

    assert_not res.success?
    assert_match(/execute/, res.error)
  end

  # The dangerous half must stay owner-only whatever else is passed.
  test "arbitrary ruby is owner-only even alongside an allowlisted task" do
    res = call("conductor_app",
               { "action" => "runner", "task" => "db:version", "ruby" => "User.destroy_all" },
               user: @editor)

    assert_not res.success?
    assert_match(/execute/, res.error, "a ruby payload must not be laundered through a safe task name")
  end

  test "arbitrary ruby alone is owner-only" do
    res = call("conductor_app", { "action" => "runner", "ruby" => "puts 1" }, user: @editor)

    assert_not res.success?
    assert_match(/execute/, res.error)
  end

  # A prefix rule would quietly admit db:migrate because db:migrate:status is safe.
  test "the allowlist matches exactly, not by prefix" do
    assert ReadOnlyRailsTasks.allow?("db:migrate:status")
    assert_not ReadOnlyRailsTasks.allow?("db:migrate")
    assert_not ReadOnlyRailsTasks.allow?("db:migrate:status:extra")
    assert_not ReadOnlyRailsTasks.allow?("db:migrate:status; rm -rf /")
  end

  test "an owner is unaffected by the allowlist" do
    res = call("conductor_app", { "action" => "runner", "ruby" => "puts 1" }, user: @owner)

    assert_no_match(/requires an organization owner/i, res.error.to_s)
  end

  test "a plain member gets nothing, allowlisted or not" do
    res = call("conductor_app", { "action" => "runner", "task" => "db:version" }, user: @member)

    assert_not res.success?
    assert_match(/owner or editor/i, res.error)
  end
end
