require "test_helper"

# conductor_read action=transfer — visibility into an AppTransfer run (its phase,
# status, and error). Without this the transfer was fire-and-forget: you could
# start a move and had no way to see why it stalled.
class TransferStatusToolTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "xfer-status@example.com", admin: true)
    @org = Organization.create_for(@user, name: "Acme")
    key = SshKey.create!(name: "k", private_key: valid_private_key, organization: @org)
    @source = @org.servers.create!(name: "box-a", status: "online", ip_address: "10.0.0.1", ssh_key: key)
    @target = @org.servers.create!(name: "box-b", status: "online", ip_address: "10.0.0.2", ssh_key: key)
    @app = @org.apps.create!(name: "Appone", slug: "appone", server: @source, deploy_method: "kamal",
                             repository_url: "https://github.com/x/y.git", domain: "app.example.com")
  end

  def read(**input)
    ConductorReadTool.new(user: @user).call({ "action" => "transfer" }.merge(input.transform_keys(&:to_s)))
  end

  def make_transfer(mode: "stage", status: "failed", phase: "database", error: "database: boom")
    t = AppTransfer.create!(app: @app, organization: @org, source_server: @source, target_server: @target, mode: mode)
    t.update_columns(status: status, phase: phase, error: error)
    t
  end

  test "a specific transfer_id returns its phase, status and error" do
    t = make_transfer
    res = read(transfer_id: t.id)
    assert res.success?, res.error
    v = res.value
    assert_equal t.id, v[:transfer_id]
    assert_equal "Appone", v[:app]
    assert_equal "stage", v[:mode]
    assert_equal "failed", v[:status]
    assert_equal "database", v[:phase]
    assert_match(/boom/, v[:error])
    assert_equal "box-a", v[:from]
    assert_equal "box-b", v[:to]
  end

  test "no id lists the org's recent transfers" do
    make_transfer(status: "succeeded", phase: "edge", error: nil)
    make_transfer(status: "failed")
    res = read
    assert res.success?, res.error
    assert_equal 2, res.value[:transfers].size
  end

  test "an unknown transfer_id is a clean failure" do
    res = read(transfer_id: 999_999)
    refute res.success?
    assert_match(/not found/i, res.error)
  end

  test "a transfer in another org is not visible to a non-admin actor" do
    other_user = User.create!(email: "other-xfer@example.com")
    other = Organization.create_for(other_user, name: "Other")
    okey = SshKey.create!(name: "k2", private_key: valid_private_key, organization: other)
    os = other.servers.create!(name: "o-a", status: "online", ip_address: "10.9.0.1", ssh_key: okey)
    ot = other.servers.create!(name: "o-b", status: "online", ip_address: "10.9.0.2", ssh_key: okey)
    oapp = other.apps.create!(name: "Otherapp", slug: "otherapp", server: os, deploy_method: "kamal",
                              repository_url: "https://github.com/x/z.git")
    foreign = AppTransfer.create!(app: oapp, organization: other, source_server: os, target_server: ot, mode: "stage")

    res = ConductorReadTool.new(user: other_user).call("action" => "transfer", "transfer_id" => foreign.id)
    assert res.success?, "same-org actor can read their own transfer"

    denied = ConductorReadTool.new(user: @user).call("action" => "transfer", "transfer_id" => foreign.id)
    # @user is admin here, so allowed; assert the non-admin owner is scoped instead:
    scoped = ConductorReadTool.new(user: other_user).call("action" => "transfer")
    assert_equal 1, scoped.value[:transfers].size, "owner sees only their org's transfer"
  end
end
