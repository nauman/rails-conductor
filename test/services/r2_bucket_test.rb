require "test_helper"

# Conductor could configure R2 storage, migrate blobs, set CORS and attach a
# public domain — everything EXCEPT create the bucket all of that depends on.
# So every R2 setup began with a manual detour to the Cloudflare dashboard.
#
# It is also how the fleet ran ten backup schedules pointed at
# `pavelabs-backups`, a bucket that did not exist: nothing in Conductor could
# create it, and nothing checked it was there.
class R2BucketTest < ActiveSupport::TestCase
  class FakeClient
    attr_reader :created, :listed
    def initialize(buckets: [], create: nil)
      @buckets = buckets
      @create = create
    end

    def r2_buckets(account_id)
      @listed = account_id
      CloudflareClient::Result.new(ok: true, data: @buckets)
    end

    def create_r2_bucket(account_id, name, location_hint: nil)
      @created = [ account_id, name, location_hint ]
      @create || CloudflareClient::Result.new(ok: true, data: { "name" => name })
    end
  end

  setup do
    user = User.create!(email: "r2@example.com")
    @org = Organization.create_for(user, name: "Acme")
    @cred = @org.credentials.create!(name: "cf", provider: "cloudflare", api_key: "tok",
                                     account_id: "acct123", verified_at: Time.current,
                                     zones: [ { "id" => "z1", "name" => "example.com" } ].to_json)
  end

  def creds = Credential.where(provider: "cloudflare")

  test "creates a bucket in the connected account" do
    fake = FakeClient.new
    r = R2Bucket.new(creds, client_for: ->(_c) { fake }).create!(name: "pavelabs-backups")

    assert r.ok?, r.message
    assert_equal [ "acct123", "pavelabs-backups", nil ], fake.created
    assert_match(/pavelabs-backups/, r.message)
  end

  # Idempotent: re-running setup must not fail because the bucket is already there.
  test "an existing bucket is reported OK, not an error" do
    fake = FakeClient.new(buckets: [ { "name" => "pavelabs-backups" } ])
    r = R2Bucket.new(creds, client_for: ->(_c) { fake }).create!(name: "pavelabs-backups")

    assert r.ok?
    assert_match(/already exists/i, r.message)
    assert_nil fake.created, "must not attempt to create it again"
  end

  # R2 names follow the same shape as the backup bucket validation, and an
  # invalid name must be refused locally rather than round-tripping an API error.
  test "an invalid bucket name is refused before any API call" do
    fake = FakeClient.new
    [ "UPPER", "has space", "x", "a" * 64, "trailing-", "semi;colon" ].each do |bad|
      r = R2Bucket.new(creds, client_for: ->(_c) { fake }).create!(name: bad)
      assert_not r.ok?, "#{bad.inspect} must be refused"
    end
    assert_nil fake.created
  end

  test "a Cloudflare failure is surfaced, not swallowed" do
    fake = FakeClient.new(create: CloudflareClient::Result.new(ok: false, error: "Authentication error"))
    r = R2Bucket.new(creds, client_for: ->(_c) { fake }).create!(name: "good-name")

    assert_not r.ok?
    assert_match(/Authentication error/, r.message)
  end

  test "no verified Cloudflare account is a clear refusal" do
    Credential.update_all(verified_at: nil)
    r = R2Bucket.new(Credential.where(provider: "cloudflare")).create!(name: "good-name")

    assert_not r.ok?
    assert_match(/verified/i, r.message)
  end

  test "lists buckets for the connected account" do
    fake = FakeClient.new(buckets: [ { "name" => "a" }, { "name" => "b" } ])
    r = R2Bucket.new(creds, client_for: ->(_c) { fake }).list

    assert r.ok?
    assert_equal %w[a b], r.buckets
  end
end
