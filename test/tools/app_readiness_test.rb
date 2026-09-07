require "test_helper"

# FIRST INSTALL is the case nothing answered. Preflight assumes a deployable app;
# a brand-new one fails at deploy with "Missing required env var(s)" after a clone
# and a build, and an agent over MCP then has nowhere to go — because the one thing
# it must NOT do is ask for the value in chat, where the answer lands in a
# transcript.
#
# So this answers what is missing and WHO can supply it. Names only, never values.
class AppReadinessTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "ar@example.com")
    @org = Organization.create_for(@user, name: "Acme")
    @server = @org.servers.create!(name: "box", status: "online", ip_address: "10.0.0.150")
    @subject = @org.apps.create!(name: "appone", slug: "appone", server: @server, deploy_method: "kamal",
                                 port: 3000, repository_url: "https://github.com/x/y.git")
  end

  def readiness(**input)
    ConductorAppTool.new(user: @user).call({ "action" => "readiness", "app_id" => @subject.id }.merge(input))
  end

  test "a brand-new app reports what it still needs" do
    result = readiness

    assert result.success?, result.error
    assert_includes result.value[:missing].map { |m| m[:key] }, "RAILS_MASTER_KEY"
  end

  # THE POINT. An agent must never ask a human to paste a secret into a chat.
  test "every missing item says how to supply it without putting it in a transcript" do
    readiness.value[:missing].each do |item|
      assert item[:supply].present?, "#{item[:key]} does not say how to supply it"
      assert_no_match(/paste|tell me|provide the value|send.*value/i, item[:supply])
    end
  end

  # Not everything missing needs a human. Conductor provisions the database, so it
  # knows that password — asking an operator for it would be asking for something
  # Conductor is about to invent.
  test "a value Conductor derives is not asked of a human" do
    @subject.update!(database_mode: "dedicated", database_placement: "colocated")

    item = readiness.value[:missing].find { |m| m[:key] == "DATABASE_URL" }

    assert_nil item, "Conductor provisions this; it must not appear as an operator task"
  end

  test "an app holding a key does not report it missing" do
    @subject.env_variables.create!(key: "RAILS_MASTER_KEY", value: "a" * 32, secret: true)

    assert_not_includes readiness.value[:missing].map { |m| m[:key] }, "RAILS_MASTER_KEY"
  end

  # Values never cross this boundary, even redacted — a name is enough to act on.
  test "no value is ever returned" do
    @subject.env_variables.create!(key: "RAILS_MASTER_KEY", value: "supersecretvalue", secret: true)

    assert_no_match(/supersecretvalue/, readiness.value.to_s)
  end

  test "readiness is available to a read-scoped token" do
    assert ToolAuthorization.read_only?("conductor_app", "readiness")
  end

  test "an app that has everything says so plainly" do
    %w[RAILS_MASTER_KEY KAMAL_REGISTRY_PASSWORD].each do |k|
      @subject.env_variables.create!(key: k, value: "x" * 32, secret: true)
    end

    result = readiness

    assert_empty result.value[:missing]
    assert_match(/ready/i, result.value[:summary])
  end
end
