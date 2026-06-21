require "test_helper"

# Server-level log tail: SSH to the box and tail the system journal by default,
# or a specific container's docker logs (incl. Conductor's own) when chosen.
class ServerLogsTest < ActionDispatch::IntegrationTest
  class FakeSsh
    attr_reader :last_command
    def initialize(output) = @output = output
    def execute(command) = (@last_command = command) && @output
    def output = @output
    def error = nil
  end

  def sign_in_as(user)
    ps = Passwordless::Session.create!(authenticatable: user)
    get "/users/sign_in/#{ps.identifier}/#{ps.token}"
  end

  setup do
    @user = User.create!(email: "logs@example.com")
    @org = Organization.create_for(@user, name: "Mine")
    @key = SshKey.create!(name: "k", private_key: valid_private_key, organization: @org)
    @server = @org.servers.create!(name: "box-1", status: "online",
                                   ip_address: "10.0.0.5", ssh_key: @key, ssh_user: "deploy")
    @conductor_app = @org.apps.create!(name: "Conductor", slug: "conductor", server: @server,
                             deploy_method: "kamal", container_status: "running")
    @user.organizations.update_all(onboarded_at: Time.current)
    sign_in_as(@user)
  end

  test "tails the system journal by default" do
    fake = FakeSsh.new("-- journal --\nboot ok")
    SshConnection.stub(:new, fake) { get logs_server_path(@server) }

    assert_response :success
    assert_match "journal", @response.body
    assert_match(/journalctl -n 300/, fake.last_command)
  end

  test "JSON endpoint returns the logs for auto-refresh" do
    fake = FakeSsh.new("line-a\nline-b")
    SshConnection.stub(:new, fake) { get logs_server_path(@server, format: :json) }

    assert_response :success
    assert_includes JSON.parse(@response.body)["logs"], "line-a"
  end

  test "tails a specific container's docker logs when chosen (e.g. Conductor's own)" do
    fake = FakeSsh.new("docker output")
    SshConnection.stub(:new, fake) { get logs_server_path(@server, container: "conductor-conductor") }

    assert_response :success
    assert_match(/docker logs --tail 300 conductor-conductor/, fake.last_command)
  end

  test "shell-escapes the container name" do
    fake = FakeSsh.new("x")
    SshConnection.stub(:new, fake) { get logs_server_path(@server, container: "a; rm -rf /") }

    refute_match("; rm -rf /", fake.last_command)
  end

  test "the source picker lists the server's app containers (incl. Conductor)" do
    fake = FakeSsh.new("x")
    SshConnection.stub(:new, fake) { get logs_server_path(@server) }

    assert_match "conductor-conductor", @response.body
  end

  test "caps the tail at 2000 lines" do
    fake = FakeSsh.new("x")
    SshConnection.stub(:new, fake) { get logs_server_path(@server, tail: 99999) }

    assert_match(/-n 2000/, fake.last_command)
  end

  test "another org's server is not viewable" do
    theirs = Organization.create!(name: "Other").servers.create!(name: "theirs", status: "offline")
    get logs_server_path(theirs)
    assert_response :not_found
  end
end
