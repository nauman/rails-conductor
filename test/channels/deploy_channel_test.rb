require "test_helper"

class DeployChannelTest < ActionCable::Channel::TestCase
  setup do
    @me = User.create!(email: "cable-me@example.com")
    org = Organization.create_for(@me, name: "Mine")
    server = org.servers.create!(name: "b", status: "online")
    my_app = org.apps.create!(name: "Mine", slug: "mine-app-c", server: server,
                              deploy_method: "docker", repository_url: "https://github.com/x/y.git")
    @my_dep = my_app.deployments.create!(status: "succeeded")

    other = Organization.create!(name: "Other")
    other_srv = other.servers.create!(name: "o", status: "online")
    other_app = other.apps.create!(name: "Other", slug: "other-app-c", server: other_srv,
                                   deploy_method: "docker", repository_url: "https://github.com/x/y.git")
    @other_dep = other_app.deployments.create!(status: "succeeded")
  end

  test "a user can subscribe to their own org's deployment stream" do
    stub_connection(current_user: @me)
    subscribe(deployment_id: @my_dep.id)
    assert subscription.confirmed?
    assert_has_stream "deployment_#{@my_dep.id}"
  end

  test "a user cannot subscribe to another org's deployment stream" do
    stub_connection(current_user: @me)
    subscribe(deployment_id: @other_dep.id)
    assert subscription.rejected?
  end
end
