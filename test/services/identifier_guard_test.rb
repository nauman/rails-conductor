require "test_helper"

# The second line of defence the docs already claimed existed. A caller-supplied
# name — from the MCP tool or the UI — never passes through App's derivation, so
# shape validation was the ONLY check standing between it and interpolated SQL.
class IdentifierGuardTest < ActiveSupport::TestCase
  setup do
    user = User.create!(email: "ig@example.com")
    org = Organization.create_for(user, name: "Acme")
    server = org.servers.create!(name: "box", status: "online", ip_address: "10.0.0.61")
    cluster = org.database_clusters.create!(name: "c", container_name: "c", server: server,
                                            admin_username: "conductor", admin_password: "x", port: 5432)
    @client = PostgresClusterClient.new(cluster)
  end

  test "an over-long identifier is refused rather than silently truncated" do
    error = assert_raises(PostgresClusterClient::Error) { @client.send(:validate_identifier!, "a" * 64) }

    assert_match(/63/, error.message)
  end

  test "a reserved word is refused rather than interpolated unquoted" do
    assert_raises(PostgresClusterClient::Error) { @client.send(:validate_identifier!, "select") }
    assert_raises(PostgresClusterClient::Error) { @client.send(:validate_identifier!, "postgres") }
  end

  # `conductor` is the admin role on every cluster Conductor manages, which is
  # exactly WHY a new role may not be called that — and also why this guard must not
  # reach the admin credential itself. It does not: the admin is shell-escaped into
  # the psql invocation, never validated as an identifier to create.
  test "the guard does not break provisioning on a conductor-admin cluster" do
    assert_nothing_raised do
      @client.send(:validate_identifier!, "appone_production")
      @client.send(:validate_identifier!, "appone")
    end
  end

  # Codex's list, transcribed. Each of these passed the hand-written version and
  # would then have failed as interpolated SQL.
  test "the reserved list covers the words a hand-written one missed" do
    %w[join like is full left right natural cross binary authorization similar
       tablesample current_catalog system_user inner limit].each do |word|
      assert_raises(PostgresClusterClient::Error, "#{word} is reserved") do
        @client.send(:validate_identifier!, word)
      end
    end
  end

  # The admin collision is in the ROLE namespace only. A database named after the
  # admin role collides with nothing, and refusing it refused a legal name.
  test "the admin-role check applies to roles, not database names" do
    assert_nothing_raised { @client.send(:validate_identifier!, "conductor") }
    assert_raises(PostgresClusterClient::Error) do
      @client.send(:validate_identifier!, "conductor", role: true)
    end
  end

  test "an ordinary name still passes" do
    assert_nothing_raised { @client.send(:validate_identifier!, "appone_production") }
    assert_nothing_raised { @client.send(:validate_identifier!, "a" * 63) }
  end
end
