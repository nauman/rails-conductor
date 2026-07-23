require "test_helper"

class ServerHealthAndPackagesTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  class FakeSsh
    def initialize(output) = @output = output
    def execute(_cmd) = @output
    def test = true
    def success? = true
    def error = nil
  end

  def sign_in_as(user)
    ps = Passwordless::Session.create!(authenticatable: user)
    get "/users/sign_in/#{ps.identifier}/#{ps.token}"
  end

  setup do
    @user = User.create!(email: "shp@example.com")
    @org = Organization.create_for(@user, name: "Mine")
    @key = SshKey.create!(name: "k", private_key: valid_private_key, organization: @org)
    @server = @org.servers.create!(name: "box-1", status: "online", ip_address: "10.0.0.5",
                                   ssh_key: @key, ssh_user: "deploy")
    @user.organizations.update_all(onboarded_at: Time.current)
    sign_in_as(@user)
  end

  test "health renders a graded check panel" do
    probe = "DISK_ROOT:42\nMEM_AVAIL_PCT:60\nLOAD1:0.1\nCORES:4\nSWAP_USED_PCT:0\nFAILED_UNITS:0\nREBOOT_REQUIRED:no\n"
    SshConnection.stub(:new, FakeSsh.new(probe)) { get health_server_path(@server) }

    assert_response :success
    assert_match "Server health", @response.body
    assert_match "healthy", @response.body
    assert_match "Disk", @response.body
  end

  test "install_packages marks running and enqueues the job" do
    assert_enqueued_with(job: InstallPackagesJob) do
      post install_packages_server_path(@server), params: { packages: "htop ncdu" }
    end
    assert_redirected_to server_path(@server)
    assert_equal "running", @server.reload.last_package_install_status
    assert_equal "htop ncdu", @server.last_package_install_packages
  end

  test "install_packages rejects an empty list without enqueuing" do
    assert_no_enqueued_jobs do
      post install_packages_server_path(@server), params: { packages: "   " }
    end
    assert_redirected_to server_path(@server)
    assert_nil @server.reload.last_package_install_status
  end

  test "InstallPackagesJob runs the installer and records the result" do
    fake = Object.new
    def fake.execute_with_status(_c) = { success: true, exit_code: 0, stdout: "Setting up htop ...", stderr: "" }

    SshConnection.stub(:new, fake) { InstallPackagesJob.perform_now(@server.id, [ "htop" ]) }

    @server.reload
    assert_equal "succeeded", @server.last_package_install_status
    assert_match "Setting up htop", @server.last_package_install_log
  end

  test "audit renders a graded security panel" do
    probe = "UFW:active\nFAIL2BAN:active\nSSH_ROOT:no\nSSH_PASSWORD:no\nSEC_UPDATES:0\nUPDATES:2\nREBOOT:no\nAUTOUPGRADE:active\nDB_PUBLIC:\n"
    SshConnection.stub(:new, FakeSsh.new(probe)) { get audit_server_path(@server) }

    assert_response :success
    assert_match "Security audit", @response.body
    assert_match "secure", @response.body
  end

  test "storage frame renders (regression: :storage must be in set_server, else @server is nil → 500)" do
    probe = "===DF===\n/dev/sda1 100 40 60 40 /\n===SWAP===\n0 0 0\n===MEM===\n8000 4000 4000\n===TOPDIRS===\n"
    SshConnection.stub(:new, FakeSsh.new(probe)) { get storage_server_path(@server) }

    assert_response :success
    assert_match "Storage", @response.body
    assert_match(/turbo-frame id=.#{ActionView::RecordIdentifier.dom_id(@server, :storage)}/, @response.body)
  end

  test "apply_updates (security) marks running and enqueues the job" do
    assert_enqueued_with(job: ApplyUpdatesJob) do
      post apply_updates_server_path(@server), params: { scope: "security" }
    end
    assert_equal "running", @server.reload.last_update_status
    assert_equal "security", @server.last_update_scope
  end

  test "apply_updates defaults an unknown scope to security (safe)" do
    post apply_updates_server_path(@server), params: { scope: "everything" }
    assert_equal "security", @server.reload.last_update_scope
  end

  test "a successful connection test refreshes metrics so the server stops reading 'pending'" do
    @server.update_columns(last_seen_at: nil, status: "offline")
    metrics = "CPU:5\nMEM_USED:1024\nMEM_TOTAL:4096\nDISK:30\nUPTIME:1000\n"
    SshConnection.stub(:new, FakeSsh.new(metrics)) do
      post test_connection_server_path(@server)
    end
    @server.reload
    assert_not_nil @server.last_seen_at, "a working test_connection must update last_seen_at"
    assert_equal "online", @server.display_status
  end
end
