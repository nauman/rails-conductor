require "test_helper"

class CloudflareClientTest < ActiveSupport::TestCase
  # Stub HTTP seam: maps a path → parsed JSON body.
  class FakeHttp
    def initialize(responses) = @responses = responses
    def get(path) = @responses.fetch(path)
  end

  test "verify returns ok when the token is valid" do
    http = FakeHttp.new("/user/tokens/verify" => { "success" => true, "result" => { "status" => "active" } })
    res = CloudflareClient.new("tok", http: http).verify
    assert res.ok?
    assert_equal "active", res.data["status"]
  end

  test "verify surfaces the Cloudflare error message" do
    http = FakeHttp.new("/user/tokens/verify" => { "success" => false, "errors" => [ { "message" => "Invalid API Token" } ] })
    res = CloudflareClient.new("bad", http: http).verify
    refute res.ok?
    assert_match(/Invalid API Token/, res.error)
  end

  test "zones returns id/name/account_id triples" do
    http = FakeHttp.new("/zones?per_page=50" => {
      "success" => true,
      "result" => [ { "id" => "z1", "name" => "calm.page", "account" => { "id" => "acct1" } } ]
    })
    res = CloudflareClient.new("tok", http: http).zones
    assert res.ok?
    assert_equal({ "id" => "z1", "name" => "calm.page", "account_id" => "acct1" }, res.data.first)
  end
end
