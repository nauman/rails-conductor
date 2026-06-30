require "test_helper"

class ServerHealthAndPackagesTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  class FakeSsh
    def initialize(output) = @output = output
    def execute(_cmd) = @output
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

    SshConnection.stub(:new, fake) { InstallPackagesJob.perform_now(@server.id, ["htop"]) }

    @server.reload
    assert_equal "succeeded", @server.last_package_install_status
    assert_match "Setting up htop", @server.last_package_install_log
  end
end
