require "test_helper"

class CredentialTest < ActiveSupport::TestCase
  setup do
    user = User.create!(email: "cred@example.com")
    @org = Organization.create_for(user, name: "Acme")
    @cf = @org.credentials.create!(name: "InventList", provider: "cloudflare", api_key: "cf-token-xyz")
  end

  # A CloudflareClient stub whose zones() returns the given result.
  def zones_client(ok:, data: [], error: nil)
    c = Object.new
    c.define_singleton_method(:zones) { CloudflareClient::Result.new(ok: ok, data: data, error: error) }
    c
  end

  test "cloudflare? + OAuth attach command uses the hosted URL, per-account name, NO token" do
    assert @cf.cloudflare?
    cmd = @cf.cloudflare_mcp_command
    assert_equal "https://mcp.cloudflare.com/mcp", Credential::CLOUDFLARE_MCP_URL
    assert_includes cmd, Credential::CLOUDFLARE_MCP_URL
    assert_includes cmd, "cloudflare-inventlist" # named per account
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
    ses = @org.credentials.create!(name: "ses", provider: "amazon_ses", api_key: "u", api_secret: "bad")
    assert_equal "535 auth invalid", ses.verify_ses!(client: client)
    refute ses.verified?
  end
end
