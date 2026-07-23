require "test_helper"

class CredentialTest < ActiveSupport::TestCase
  setup do
    user = User.create!(email: "cred@example.com")
    @org = Organization.create_for(user, name: "Acme")
    @cf = @org.credentials.create!(name: "InventList", provider: "cloudflare", api_key: "cf-token-xyz")
  end

  test "cloudflare? + attach command carries the account token and URL" do
    assert @cf.cloudflare?
    cmd = @cf.cloudflare_mcp_command
    assert_includes cmd, Credential::CLOUDFLARE_MCP_URL
    assert_includes cmd, "Bearer cf-token-xyz"
    assert_includes cmd, "cloudflare-inventlist" # named per account
  end

  test "verify_cloudflare! caches account_id + zones and marks verified" do
    client = Object.new
    client.define_singleton_method(:verify) { CloudflareClient::Result.new(ok: true, data: {}) }
    client.define_singleton_method(:zones) do
      CloudflareClient::Result.new(ok: true, data: [ { "id" => "z1", "name" => "calm.page", "account_id" => "acct1" } ])
    end

    assert_nil @cf.verify_cloudflare!(client: client) # nil = success
    assert @cf.verified?
    assert_equal "acct1", @cf.account_id
    assert_equal [ "calm.page" ], @cf.zones_list.map { |z| z["name"] }
  end

  test "verify_cloudflare! returns the error string on a bad token" do
    client = Object.new
    client.define_singleton_method(:verify) { CloudflareClient::Result.new(ok: false, error: "Invalid API Token") }
    assert_equal "Invalid API Token", @cf.verify_cloudflare!(client: client)
    refute @cf.verified?
  end

  test "zones_list is empty and safe before verification" do
    assert_equal [], @cf.zones_list
  end
end
