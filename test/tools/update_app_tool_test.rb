require "test_helper"

# conductor_app action=update — focus on the home-server change (adopt/correct
# where Conductor records an app lives, e.g. after a hand-moved deploy), which
# unblocks retiring the old box without a full transfer.
class UpdateAppToolTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "upd@example.com", admin: true)
    @org = Organization.create_for(@user, name: "Acme")
    key = SshKey.create!(name: "k", private_key: valid_private_key, organization: @org)
    @a = @org.servers.create!(name: "box-a", status: "online", ip_address: "10.0.0.1", ssh_key: key)
    @b = @org.servers.create!(name: "box-b", status: "online", ip_address: "10.0.0.2", ssh_key: key)
    @app = @org.apps.create!(name: "Appone", slug: "appone", server: @a, deploy_method: "kamal",
                             repository_url: "https://github.com/x/y.git")
  end

  def run_tool(**over)
    ConductorAppTool.new(user: @user).call({ "action" => "update", "app_name" => "Appone" }.merge(over.transform_keys(&:to_s)))
  end

  test "moves the app's home server by name" do
    res = run_tool(server_name: "box-b")
    assert res.success?, res.error
    assert_equal @b.id, @app.reload.server_id
  end

  test "moves the app's home server by id" do
    res = run_tool(server_id: @b.id)
    assert res.success?, res.error
    assert_equal @b.id, @app.reload.server_id
  end

  test "an unknown server is a clean failure and doesn't move the app" do
    res = run_tool(server_name: "ghost")
    refute res.success?
    assert_match(/not found/i, res.error)
    assert_equal @a.id, @app.reload.server_id
  end

  test "refuses a server from another organization (no cross-org home)" do
    other = Organization.create_for(User.create!(email: "o@example.com"), name: "Other")
    okey = SshKey.create!(name: "k2", private_key: valid_private_key, organization: other)
    foreign = other.servers.create!(name: "o-box", status: "online", ip_address: "10.9.0.1", ssh_key: okey)
    res = run_tool(server_id: foreign.id)
    refute res.success?, "a non-admin/foreign server must not become the home"
    assert_equal @a.id, @app.reload.server_id
  end

  test "still updates ordinary fields, and rejects an empty update" do
    assert run_tool(notes: "moved by hand").success?
    assert_equal "moved by hand", @app.reload.notes
    refute run_tool.success?
  end
end
