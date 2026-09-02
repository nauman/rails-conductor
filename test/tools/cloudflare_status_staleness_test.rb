require "test_helper"

# The zone list is a CACHE written by verify_cloudflare! and refreshed by nothing.
# It sat 34 days old while Conductor answered questions from it — reporting a real
# domain as absent, and a deleted one as present. Nothing in the output said how
# old it was, so an agent (and I) read a snapshot as the live state and went looking
# for a permissions problem that did not exist.
#
# Same failure as the deploy hold citing a shipped fix and the residue detector
# reading only exited containers: a stale record with no age on it reads as truth.
class CloudflareStatusStalenessTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "cfs@example.com")
    @org = Organization.create_for(@user, name: "Acme")
    @cred = @org.credentials.create!(name: "CF", provider: "cloudflare", api_key: "tok")
    @cred.update_columns(zones: [ { "id" => "z1", "name" => "example.test" } ].to_json,
                         account_id: "acct", verified_at: 34.days.ago)
  end

  def account = CloudflareStatusTool.new(user: @user).call({}).value[:connected_accounts].first

  test "the output says when the zone list was last refreshed" do
    assert account[:zones_checked_at].present?, "an undated cache cannot be judged"
  end

  test "a month-old zone list is marked stale" do
    assert account[:zones_stale], "34 days must not read as current"
  end

  test "a freshly verified list is not marked stale" do
    @cred.update_columns(verified_at: Time.current)

    assert_not account[:zones_stale]
  end

  # Never verified is the most misleading state of all — an empty list that has
  # never been populated looks identical to an account genuinely owning no zones.
  test "a never-verified credential is stale, not merely undated" do
    @cred.update_columns(verified_at: nil)

    assert account[:zones_stale]
    assert_nil account[:zones_checked_at]
  end

  # The remedy must travel with the finding (ADR 0007), or the reader has to know
  # that re-verification is even a thing.
  test "a stale list carries the action that refreshes it" do
    assert_match(/verify/i, account[:zones_hint].to_s)
  end
end
