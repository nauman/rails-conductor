require "test_helper"

class PostgresClusterClientTest < ActiveSupport::TestCase
  FakeSsh = Struct.new(:responses, :error) do
    attr_reader :commands

    def initialize(responses)
      super(responses, nil)
      @commands = []
    end

    def execute_with_status(command)
      @commands << command
      response = responses.shift || {}
      self.error = response[:error]
      {
        success: response.fetch(:success, true),
        exit_code: response.fetch(:success, true) ? 0 : 1,
        stdout: response[:stdout].to_s,
        stderr: response[:stderr].to_s,
        output: response[:stdout].to_s
      }
    end
  end

  def build_cluster
    DatabaseCluster.new(
      name: "shared",
      container_name: "conductor-postgres",
      admin_username: "conductor",
      admin_password: "adminpw",
      port: 5432
    )
  end

  # The SQL is base64-encoded into the command; decode it to assert on it.
  def sql_in(command)
    require "base64"
    Base64.decode64(command[/echo (\S+) \|/, 1].to_s)
  end

  test "create_database issues CREATE ROLE then CREATE DATABASE on the cluster" do
    ssh = FakeSsh.new([ { stdout: "" }, { stdout: "" } ])
    client = PostgresClusterClient.new(build_cluster, ssh_connection: ssh)

    result = client.create_database(name: "wiseherds_production", username: "wiseherds", password: "s3cret")

    assert_equal "created", result["action"]
    assert_equal 2, ssh.commands.size
    assert_match(/CREATE ROLE wiseherds LOGIN PASSWORD/, sql_in(ssh.commands[0]))
    assert_match(/CREATEDB/, sql_in(ssh.commands[0]))
    assert_match(/CREATE DATABASE wiseherds_production OWNER wiseherds/, sql_in(ssh.commands[1]))
    # runs through docker exec against the cluster's container as the admin user
    assert_match(/docker exec.*conductor-postgres.*psql -U conductor/, ssh.commands[0])
  end

  test "drop_database issues DROP DATABASE then DROP ROLE" do
    ssh = FakeSsh.new([ { stdout: "" }, { stdout: "" } ])
    client = PostgresClusterClient.new(build_cluster, ssh_connection: ssh)

    client.drop_database(name: "wiseherds_production", username: "wiseherds")

    assert_match(/DROP DATABASE IF EXISTS wiseherds_production/, sql_in(ssh.commands[0]))
    assert_match(/DROP ROLE IF EXISTS wiseherds/, sql_in(ssh.commands[1]))
  end

  test "rejects invalid SQL identifiers (no injection)" do
    client = PostgresClusterClient.new(build_cluster, ssh_connection: FakeSsh.new([]))

    assert_raises(PostgresClusterClient::Error) do
      client.create_database(name: "x; DROP DATABASE postgres", username: "x", password: "y")
    end
  end

  test "raises when the SSH command fails" do
    ssh = FakeSsh.new([ { success: false, stderr: "role exists" } ])
    client = PostgresClusterClient.new(build_cluster, ssh_connection: ssh)

    assert_raises(PostgresClusterClient::Error) do
      client.create_database(name: "dup", username: "dup", password: "p")
    end
  end
end
