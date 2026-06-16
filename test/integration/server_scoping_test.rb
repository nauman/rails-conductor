require "test_helper"

class ServerScopingTest < ActionDispatch::IntegrationTest
  def sign_in_as(user)
    ps = Passwordless::Session.create!(authenticatable: user)
    get "/users/sign_in/#{ps.identifier}/#{ps.token}"
  end

  setup do
    @user = User.create!(email: "u@example.com")
    @org = Organization.create_for(@user, name: "Mine")
    @mine = @org.servers.create!(name: "mine-server", status: "offline")
    @other_org = Organization.create!(name: "Other")
    @theirs = @other_org.servers.create!(name: "theirs-server", status: "offline")
    @user.organizations.update_all(onboarded_at: Time.current)
    sign_in_as(@user)
  end

  test "index lists only the current org's servers" do
    get servers_path
    assert_response :success
    assert_match "mine-server", @response.body
    assert_no_match "theirs-server", @response.body
  end

  test "cannot view another org's server" do
    get server_path(@theirs)
    assert_response :not_found
  end

  test "creating a server assigns it to the current org" do
    assert_difference -> { @org.servers.count }, 1 do
      post servers_path, params: { server: { name: "new-one", status: "offline" } }
    end
  end

  test "dashboard shows only the current org's servers" do
    get dashboard_path
    assert_response :success
    assert_match "mine-server", @response.body
    assert_no_match "theirs-server", @response.body
  end
end
