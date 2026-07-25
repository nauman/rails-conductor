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

class CloudflareClientWriteTest < ActiveSupport::TestCase
  class FakeHttp
    attr_reader :patched, :posted
    def initialize(responses) = (@responses = responses; @patched = []; @posted = [])
    def get(path) = @responses.fetch(path)
    def patch(path, body) = (@patched << [ path, body ]; { "success" => true, "result" => body })
    def post(path, body) = (@posted << [ path, body ]; { "success" => true, "result" => { "id" => "purge1" } })
  end

  test "set_proxied PATCHes the record with proxied:true" do
    http = FakeHttp.new({})
    CloudflareClient.new("t", http: http).set_proxied("z1", "rec1", true)
    assert_equal [ "/zones/z1/dns_records/rec1", { proxied: true } ], http.patched.first
  end

  test "set_ssl_mode PATCHes the zone ssl setting" do
    http = FakeHttp.new({})
    CloudflareClient.new("t", http: http).set_ssl_mode("z1", "full")
    assert_equal [ "/zones/z1/settings/ssl", { value: "full" } ], http.patched.first
  end

  test "purge_cache POSTs purge_everything when no files given" do
    http = FakeHttp.new({})
    res = CloudflareClient.new("t", http: http).purge_cache("z1")
    assert res.ok?
    assert_equal [ "/zones/z1/purge_cache", { purge_everything: true } ], http.posted.first
  end

  test "purge_cache POSTs the file list when files given" do
    http = FakeHttp.new({})
    CloudflareClient.new("t", http: http).purge_cache("z1", files: [ "https://x/a.css" ])
    assert_equal [ "/zones/z1/purge_cache", { files: [ "https://x/a.css" ] } ], http.posted.first
  end
end
