require "test_helper"

# R2 audit fix (finding 1): buckets bind to the org that first uses them, so a
# shared Cloudflare account can't let one org touch another's bucket.
class StorageBucketTest < ActiveSupport::TestCase
  setup do
    @org = Organization.create_for(User.create!(email: "sb-a@example.com"), name: "A")
    @other = Organization.create_for(User.create!(email: "sb-b@example.com"), name: "B")
  end

  test "claim! binds a new bucket to the acting org" do
    b = StorageBucket.claim!(organization: @org, account_id: "acct1", name: "assets")
    assert_equal @org, b.organization
    assert_equal 1, StorageBucket.count
  end

  test "claim! is idempotent for the same org + account + name" do
    first = StorageBucket.claim!(organization: @org, account_id: "acct1", name: "assets")
    second = StorageBucket.claim!(organization: @org, account_id: "acct1", name: "assets")
    assert_equal first.id, second.id
    assert_equal 1, StorageBucket.count
  end

  test "claim! raises CrossOrg for a bucket owned by another org on the same account" do
    StorageBucket.claim!(organization: @other, account_id: "acct1", name: "assets")
    assert_raises(StorageBucket::CrossOrg) do
      StorageBucket.claim!(organization: @org, account_id: "acct1", name: "assets")
    end
  end

  test "same bucket name on a DIFFERENT account is not a conflict" do
    StorageBucket.claim!(organization: @other, account_id: "acct1", name: "assets")
    assert_nothing_raised do
      StorageBucket.claim!(organization: @org, account_id: "acct2", name: "assets")
    end
  end

  test "claim! backfills the app link when first claimed without one" do
    key = SshKey.create!(name: "k", private_key: valid_private_key, organization: @org)
    server = @org.servers.create!(name: "s", status: "online", ip_address: "10.0.0.1", ssh_key: key)
    app = @org.apps.create!(name: "App", slug: "app", server: server, deploy_method: "kamal")

    StorageBucket.claim!(organization: @org, account_id: "acct1", name: "assets")
    b = StorageBucket.claim!(organization: @org, account_id: "acct1", name: "assets", app: app)
    assert_equal app, b.reload.app
  end
end
