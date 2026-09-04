require "test_helper"

# Dropping is where a naming policy becomes destructive. A name that already exists
# must stay droppable whatever a later rule says about creating it — and a failed
# drop must never lose the record that tracks the live database.
class DropSafetyTest < ActiveSupport::TestCase
  setup do
    user = User.create!(email: "ds@example.com")
    @org = Organization.create_for(user, name: "Acme")
    @server = @org.servers.create!(name: "box", status: "online", ip_address: "10.0.0.70")
    @cluster = @org.database_clusters.create!(name: "c", container_name: "c", server: @server,
                                              admin_username: "conductor", admin_password: "x", port: 5432)
  end

  # THE REGRESSION. A creation-time policy applied to deletion makes existing
  # databases undroppable through Conductor — and the caller then deletes the row.
  test "a name the creation policy now refuses can still be dropped" do
    ssh = FakeSsh.new([ { stdout: "" }, { stdout: "" } ])
    client = PostgresClusterClient.new(@cluster, ssh_connection: ssh)

    assert_nothing_raised { client.drop_database(name: "admin", username: "conductor") }
  end

  # Shape is still enforced on the drop path, because that is injection, not policy.
  test "an unsafe identifier is still refused on the drop path" do
    client = PostgresClusterClient.new(@cluster, ssh_connection: FakeSsh.new([]))

    assert_raises(PostgresClusterClient::Error) do
      client.drop_database(name: "x; DROP DATABASE postgres", username: "x")
    end
  end

  class FakeSsh
    attr_reader :commands
    def initialize(results) = (@results = results; @commands = [])
    def execute_with_status(command)
      @commands << command
      (@results.shift || { stdout: "" }).reverse_merge(success: true, stdout: "", stderr: "")
    end
    def error = nil
  end
end
