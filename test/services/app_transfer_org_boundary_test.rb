require "test_helper"

# The org boundary for app transfers (spec 26). A transfer moves an app, its
# database, and its DNS onto another server — none of that may cross an org.
#
# The important case is the last one: the MCP tool already confines an org-bound
# caller through ActorScoped, so a lookup-layer guard *looks* sufficient. It isn't.
# An actor with no bound org (the legacy shared CONDUCTOR_MCP_TOKEN, which runs as
# the first admin with global scope) sees App.all / Server.all, so it can hand the
# services a cross-org pair. The guard has to live where the mutation is decided.
class AppTransferOrgBoundaryTest < ActiveSupport::TestCase
  setup do
    owner_a = User.create!(email: "a@example.com")
    @org_a = Organization.create_for(owner_a, name: "Org A")
    owner_b = User.create!(email: "b@example.com")
    @org_b = Organization.create_for(owner_b, name: "Org B")

    @key_a = SshKey.create!(name: "ka", private_key: valid_private_key, organization: @org_a)
    @key_b = SshKey.create!(name: "kb", private_key: valid_private_key, organization: @org_b)

    @source = @org_a.servers.create!(name: "a-box", status: "online", ip_address: "10.0.0.1",
                                     ssh_key: @key_a, ssh_user: "deploy", edge_type: "caddy")
    @a_target = @org_a.servers.create!(name: "a-box-2", status: "online", ip_address: "10.0.0.2",
                                       ssh_key: @key_a, ssh_user: "deploy", edge_type: "caddy")
    @b_target = @org_b.servers.create!(name: "b-box", status: "online", ip_address: "10.0.1.1",
                                       ssh_key: @key_b, ssh_user: "deploy", edge_type: "caddy")

    @app = @org_a.apps.create!(name: "Appone", slug: "appone", server: @source, deploy_method: "kamal",
                               repository_url: "https://github.com/x/y.git", domain: "app.example.com")
  end

  test "planning a transfer onto another org's server is refused" do
    error = assert_raises(AppTransferPlan::InvalidTarget) do
      AppTransferPlan.new(app: @app, target_server: @b_target).call
    end
    assert_match(/cross-organization/i, error.message)
    assert_match(/Org A/, error.message)
    assert_match(/Org B/, error.message)
  end

  test "planning within the same org still works" do
    assert AppTransferPlan.new(app: @app, target_server: @a_target).call
  end

  test "an app with no organization is refused rather than treated as unowned" do
    @app.update_columns(organization_id: nil)
    error = assert_raises(AppTransferPlan::InvalidTarget) do
      AppTransferPlan.new(app: @app.reload, target_server: @a_target).call
    end
    assert_match(/no organization/i, error.message)
  end

  # The case a lookup-layer guard misses: a global-scope actor (no bound org)
  # can see both orgs' records, so the services must refuse the pair themselves.
  test "a global-scope actor cannot plan across orgs even though it can see both" do
    Current.org_scoped = false # what a shared-token/admin actor looks like
    Current.organization = nil

    assert_raises(AppTransferPlan::InvalidTarget) do
      AppTransferPlan.new(app: @app, target_server: @b_target).call
    end
  ensure
    Current.reset
  end

  test "the runner re-checks at execute time, after the plan was made" do
    transfer = AppTransfer.create!(app: @app, organization: @org_a, source_server: @source,
                                   target_server: @a_target, mode: "transfer", status: "pending")
    # The app moves orgs between planning and running — the plan is now stale.
    @app.update_columns(organization_id: @org_b.id)

    refute AppTransferRunner.new(transfer.reload).run
    assert_equal "failed", transfer.reload.status
    assert_match(/cross-organization/i, transfer.error)
  end

  test "a transfer record cannot be persisted across orgs" do
    transfer = AppTransfer.new(app: @app, organization: @org_a, source_server: @source,
                               target_server: @b_target, mode: "transfer", status: "pending")
    refute transfer.valid?
    assert_match(/another organization/i, transfer.errors[:target_server].join)
  end

  test "a transfer record cannot borrow another org's app" do
    transfer = AppTransfer.new(app: @app, organization: @org_b, source_server: @b_target,
                               target_server: @a_target, mode: "transfer", status: "pending")
    refute transfer.valid?
    assert_match(/another organization/i, transfer.errors[:app].join)
  end
end
