require "test_helper"

class AppRestartTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    user = User.create!(email: "restart@example.com")
    @org = Organization.create_for(user, name: "Restart")
    @org.update!(onboarded_at: Time.current)
    key = SshKey.create!(name: "restart-key", private_key: valid_private_key, organization: @org)
    @server = @org.servers.create!(name: "restart-host", status: "online", ip_address: "10.0.0.30",
                                   ssh_key: key, ssh_user: "deploy")
    @managed_app = @org.apps.create!(name: "Restart app", slug: "restart-app", server: @server,
                                     deploy_method: "docker")
    session = Passwordless::Session.create!(authenticatable: user)
    get "/users/sign_in/#{session.identifier}/#{session.token}"
  end

  test "restart rejects an app without usable SSH" do
    @managed_app.update!(server: nil)

    assert_no_enqueued_jobs do
      post restart_app_path(@managed_app)
    end

    assert_redirected_to app_path(@managed_app)
    follow_redirect!
    assert_includes response.body, "Restart is unavailable"
  end

  test "restart remains supported for Docker Kamal and native apps" do
    %w[docker kamal native].each do |method|
      @managed_app.update!(deploy_method: method)

      assert_enqueued_with(job: RestartAppJob, args: [@managed_app.id]) do
        post restart_app_path(@managed_app)
      end
    end
  end
end
