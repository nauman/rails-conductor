require "test_helper"

class CredentialTest < ActiveSupport::TestCase
  setup do
    user = User.create!(email: "cred@example.com")
    @org = Organization.create_for(user, name: "Acme")
    @cf = @org.credentials.create!(name: "InventList", provider: "cloudflare", api_key: "cf-token-xyz")
  end

  test "an SES credential requires a region (blank region would silently 535)" do
    ses = @org.credentials.build(name: "SES", provider: "amazon_ses", api_key: "user", api_secret: "pass")
    refute ses.valid?
    assert_match(/region/i, ses.errors[:region].join)
    ses.region = "eu-west-1"
    assert ses.valid?, ses.errors.full_messages.join(", ")
  end

  test "region stays optional for non-SES providers" do
    assert @cf.valid? # cloudflare, no region set
  end

  # Happened in production (calm.page, 2026-07-28): the SMTP endpoint was pasted
  # into Region, so SesClient dialled email-smtp.email-smtp.<region>.amazonaws.com
  # .amazonaws.com and Verify could never pass — with nothing saying why.
  test "an SES region must be a region, not the SMTP hostname" do
    ses = @org.credentials.build(name: "SES", provider: "amazon_ses", api_key: "u", api_secret: "p",
                                 region: "email-smtp.ap-southeast-2.amazonaws.com")
    refute ses.valid?
    assert_match(/not a hostname/i, ses.errors[:region].join)

    ses.region = "ap-southeast-2"
    assert ses.valid?, ses.errors.full_messages.join(", ")
  end

  test "longer AWS region forms are accepted" do
    %w[us-gov-west-1 eusc-de-east-1 ap-southeast-2].each do |region|
      ses = @org.credentials.build(name: "SES", provider: "amazon_ses", api_key: "u", api_secret: "p",
                                   region: region)
      assert ses.valid?, "#{region} should be accepted: #{ses.errors.full_messages.join(', ')}"
    end
  end

  # A row saved before the region rule existed still holds a hostname. Verify must
  # say so, not dial a doubled host and then 500 on update!(verified_at:).
  test "verifying a legacy SES row with a bad region reports the problem instead of raising" do
    ses = @org.credentials.build(name: "SES", provider: "amazon_ses", api_key: "u", api_secret: "p",
                                 region: "email-smtp.ap-southeast-2.amazonaws.com")
    ses.save!(validate: false)
    client = Object.new
    client.define_singleton_method(:verify) { raise "must not dial with an invalid record" }

    error = ses.verify_ses!(client: client)

    assert_match(/not a hostname/i, error)
    assert_nil ses.reload.verified_at
  end

  # A CloudflareClient stub whose zones() returns the given result.
  def zones_client(ok:, data: [], error: nil)
    c = Object.new
    c.define_singleton_method(:zones) { CloudflareClient::Result.new(ok: ok, data: data, error: error) }
    c
  end

  test "cloudflare? + OAuth attach attaches ONLY read-only scoped servers, per-account, NO token" do
    assert @cf.cloudflare?
    cmd = @cf.cloudflare_mcp_command

    # Only the curated read-only servers — one attach line each.
    assert_equal Credential::CLOUDFLARE_MCP_SERVERS.size, cmd.lines.size
    Credential::CLOUDFLARE_MCP_SERVERS.each_value { |url| assert_includes cmd, url }
    assert_includes cmd, "cf-inventlist-docs" # named per account + capability

    # Never the broad aggregate or any mutating server.
    refute_includes cmd, "https://mcp.cloudflare.com/mcp", "must not attach the broad aggregate"
    refute_includes cmd, "bindings.mcp.cloudflare.com", "must not attach the Workers-mutating server"

    # OAuth only — no secret material in the command.
    refute_includes cmd, "cf-token-xyz", "OAuth attach must not embed the token"
    refute_includes cmd, "Bearer"
  end

  test "verify_cloudflare! caches account_id + zones and marks verified" do
    client = zones_client(ok: true, data: [ { "id" => "z1", "name" => "calm.page", "account_id" => "acct1" } ])

    assert_nil @cf.verify_cloudflare!(client: client) # nil = success
    assert @cf.verified?
    assert_equal "acct1", @cf.account_id
    assert_equal [ "calm.page" ], @cf.zones_list.map { |z| z["name"] }
  end

  test "verifies via zones even when /user/tokens/verify would reject an account-scoped token" do
    # The account-scoped token bug: verify() would fail, but zones() works — so we
    # must NOT gate on verify(). This client's verify() blows up if called.
    client = zones_client(ok: true, data: [ { "id" => "z", "name" => "kuickr.co", "account_id" => "a" } ])
    client.define_singleton_method(:verify) { raise "must not call /user/tokens/verify" }

    assert_nil @cf.verify_cloudflare!(client: client)
    assert @cf.verified?
  end

  test "verify_cloudflare! returns the error string when zones can't be read" do
    client = zones_client(ok: false, error: "Invalid API Token")
    assert_equal "Invalid API Token", @cf.verify_cloudflare!(client: client)
    refute @cf.verified?
  end

  test "zones_list is empty and safe before verification" do
    assert_equal [], @cf.zones_list
  end

  test "verify_ses! passes when the SES client accepts, records verified_at" do
    client = Object.new
    client.define_singleton_method(:verify) { SesClient::Result.new(ok: true, data: { "host" => "h" }) }
    ses = @org.credentials.create!(name: "ses", provider: "amazon_ses", api_key: "u", api_secret: "p", region: "us-east-1")
    assert ses.ses?
    assert ses.verifiable?
    assert_nil ses.verify_ses!(client: client)
    assert ses.verified?
  end

  test "verify_ses! returns the SMTP error on bad creds" do
    client = Object.new
    client.define_singleton_method(:verify) { SesClient::Result.new(ok: false, error: "535 auth invalid") }
    ses = @org.credentials.create!(name: "ses", provider: "amazon_ses", api_key: "u", api_secret: "bad", region: "us-east-1")
    assert_equal "535 auth invalid", ses.verify_ses!(client: client)
    refute ses.verified?
  end

  # Rotating a token must not inherit the old proof: `verified?` has to describe
  # the values that are actually stored now, and the cached zone list may belong
  # to an account the new token cannot reach.
  test "changing a credential's identity clears its verification and cached zones" do
    @cf.update!(verified_at: Time.current, zones: [ { "id" => "z1", "name" => "example.com" } ].to_json,
                account_id: "acct1")
    assert @cf.verified?

    @cf.update!(api_key: "a-rotated-token")

    refute @cf.reload.verified?, "a rotated token has not been verified"
    assert_equal [], @cf.zones_list, "cached zones describe the old token's account"
  end

  test "an unrelated edit keeps the verification" do
    @cf.update!(verified_at: Time.current, zones: [ { "id" => "z1", "name" => "example.com" } ].to_json)
    @cf.update!(name: "Renamed")

    assert @cf.reload.verified?, "renaming does not change what the credential is"
    assert_equal 1, @cf.zones_list.size
  end

  test "verifying does not clear the verification it just wrote" do
    client = zones_client(ok: true, data: [ { "id" => "z9", "name" => "example.com", "account_id" => "acct9" } ])
    @cf.verify_cloudflare!(client: client)

    assert @cf.reload.verified?, "verify writes account_id; that must not trip the invalidation"
    assert_equal 1, @cf.zones_list.size
  end
end
