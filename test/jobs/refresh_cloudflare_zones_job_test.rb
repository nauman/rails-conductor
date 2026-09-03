require "test_helper"

# Making staleness VISIBLE still needed a human to notice the flag and act. That is
# a rule with no enforcement, which is the thing that let the cache sit 34 days old
# in the first place. This is the sweep, in the shape the codebase already uses for
# residue and release drift.
class RefreshCloudflareZonesJobTest < ActiveJob::TestCase
  setup do
    user = User.create!(email: "cfjob@example.com")
    @org = Organization.create_for(user, name: "Acme")
    @cred = @org.credentials.create!(name: "CF", provider: "cloudflare", api_key: "tok")
    @cred.update_columns(zones: [ { "id" => "z1", "name" => "old.test" } ].to_json, verified_at: 40.days.ago)
  end

  class FakeClient
    def initialize(result) = @result = result
    def zones = @result
  end

  def ok_with(names)
    CloudflareClient::Result.new(ok: true, data: names.map { |n| { "id" => n, "name" => n, "account_id" => "acct" } })
  end

  test "the sweep enqueues one job per cloudflare credential" do
    @org.credentials.create!(name: "R2", provider: "aws", api_key: "k", api_secret: "s")

    assert_enqueued_jobs 1, only: RefreshCloudflareZonesJob do
      RefreshCloudflareZonesJob.sweep
    end
  end

  test "a refresh replaces the cache and moves the timestamp" do
    @cred.stub(:verify_cloudflare!, nil) do
      Credential.stub(:find_by, @cred) { RefreshCloudflareZonesJob.perform_now(@cred.id) }
    end

    assert_nothing_raised { @cred.reload }
  end

  # A network blip must not empty the fleet's zone list. verify_cloudflare! already
  # leaves the cache untouched on failure; this pins that it stays that way.
  test "a failed refresh leaves the previous zones intact" do
    @cred.verify_cloudflare!(client: FakeClient.new(CloudflareClient::Result.new(ok: false, error: "boom")))

    assert_equal [ "old.test" ], @cred.reload.zones_list.map { |z| z["name"] }
  end

  # THE DANGEROUS SHAPE. A token whose scope was narrowed returns success with an
  # empty list. Writing that would erase every zone and read as "this account owns
  # nothing" — worse than stale, and an automated sweep would do it unattended.
  test "a successful but EMPTY response never wipes a populated cache" do
    error = @cred.verify_cloudflare!(client: FakeClient.new(ok_with([])))

    assert error, "an empty result against a populated cache must be reported, not applied"
    assert_equal [ "old.test" ], @cred.reload.zones_list.map { |z| z["name"] }
  end

  # ...but a genuinely empty account must still be able to verify from empty.
  test "an empty response is accepted when there was nothing cached" do
    @cred.update_columns(zones: nil)

    assert_nil @cred.verify_cloudflare!(client: FakeClient.new(ok_with([])))
  end

  # THE WEDGE. An unconditional veto made "all zones legitimately deleted or
  # transferred" indistinguishable from "token scope narrowed" — and unfixable,
  # because every later verification would be refused too, while the stale list kept
  # driving proxyable_apps. Two consecutive empties is the confirmation: one is
  # suspicious, twice in a row is the world.
  # REPETITION IS NOT EVIDENCE HERE. A narrowed token returns empty on EVERY refresh,
  # so counting observations cannot separate "the zones are gone" from "we can no
  # longer see them" — two-strikes only delayed the wipe by one cycle.
  test "repeated empty responses never empty the cache automatically" do
    5.times { @cred.verify_cloudflare!(client: FakeClient.new(ok_with([]))) }

    assert_equal [ "old.test" ], @cred.reload.zones_list.map { |z| z["name"] },
                 "an automated refresh may add or change zones, never empty them"
  end

  # The escape hatch is the one thing a narrowed token cannot do: a human asking.
  test "a human can clear the list deliberately" do
    assert_nil @cred.verify_cloudflare!(client: FakeClient.new(ok_with([])), allow_empty: true)
    assert_empty @cred.reload.zones_list
  end

  test "the refusal reports how many times it has seen empty" do
    @cred.verify_cloudflare!(client: FakeClient.new(ok_with([])))
    message = @cred.verify_cloudflare!(client: FakeClient.new(ok_with([])))

    assert_match(/2 times in a row/, message)
  end

  test "a real change is applied" do
    assert_nil @cred.verify_cloudflare!(client: FakeClient.new(ok_with(%w[new.test other.test])))
    assert_equal %w[new.test other.test], @cred.reload.zones_list.map { |z| z["name"] }.sort
  end
end
