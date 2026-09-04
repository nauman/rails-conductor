require "test_helper"

# THREE paths create a cluster, not two: the MCP tool, this UI form, and the
# dedicated provisioner. A column that two of them populate is still inferred.
class ClusterRegistrationKindTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(email: "crk@example.com")
    @org = Organization.create_for(@user, name: "Acme")
    @org.update!(onboarded_at: Time.current)
    @server = @org.servers.create!(name: "box", status: "online", ip_address: "10.0.0.80")
    session_record = Passwordless::Session.create!(authenticatable: @user)
    get "/users/sign_in/#{session_record.to_param}/#{session_record.token}"
  end

  def register(overrides = {})
    post database_clusters_path, params: { database_cluster: {
      server_id: @server.id, name: "ui-pg", container_name: "ui-pg",
      admin_username: "conductor", admin_password: "s3cret", port: 5432
    }.merge(overrides) }
  end

  test "the UI registration form records the cluster as shared" do
    register

    assert_equal "shared", DatabaseCluster.find_by(container_name: "ui-pg")&.kind
  end

  # Registering means a human typed the container's name. Letting the form claim
  # "dedicated" would let a caller assert Conductor assigned a name it did not —
  # which is the inference this column exists to replace.
  test "a form cannot claim its cluster is dedicated" do
    register(container_name: "liar-pg", kind: "dedicated")

    assert_equal "shared", DatabaseCluster.find_by(container_name: "liar-pg")&.kind
  end
end
