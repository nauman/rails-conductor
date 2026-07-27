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
    attr_reader :patched, :posted, :putted, :deleted
    def initialize(responses) = (@responses = responses; @patched = []; @posted = []; @putted = []; @deleted = [])
    def get(path) = @responses.fetch(path)
    def patch(path, body) = (@patched << [ path, body ]; { "success" => true, "result" => body })
    def post(path, body) = (@posted << [ path, body ]; @responses.fetch(path) { { "success" => true, "result" => { "id" => "purge1" } } })
    def put(path, body) = (@putted << [ path, body ]; @responses.fetch(path) { { "success" => true, "result" => body } })
    def delete(path) = (@deleted << path; @responses.fetch(path) { { "success" => true, "result" => { "id" => path.split("/").last } } })
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

  test "upsert_dns_record POSTs a new record when none exists" do
    http = FakeHttp.new("/zones/z1/dns_records?name=old.x.com" => { "success" => true, "result" => [] })
    res = CloudflareClient.new("t", http: http).upsert_dns_record("z1", name: "old.x.com", content: "1.2.3.4")
    assert res.ok?
    assert_equal "/zones/z1/dns_records", http.posted.first[0]
    assert_equal({ type: "A", name: "old.x.com", content: "1.2.3.4", proxied: false, ttl: 1 }, http.posted.first[1])
  end

  test "upsert_dns_record PATCHes the existing record when one is present" do
    http = FakeHttp.new("/zones/z1/dns_records?name=old.x.com" => { "success" => true, "result" => [ { "id" => "rec9" } ] })
    CloudflareClient.new("t", http: http).upsert_dns_record("z1", name: "old.x.com", content: "9.9.9.9", proxied: true)
    assert_equal "/zones/z1/dns_records/rec9", http.patched.first[0]
    assert_equal true, http.patched.first[1][:proxied]
    assert_empty http.posted
  end

  test "delete_dns_record DELETEs the record by id" do
    http = FakeHttp.new({})
    res = CloudflareClient.new("t", http: http).delete_dns_record("z1", "rec9")
    assert res.ok?
    assert_equal "/zones/z1/dns_records/rec9", http.deleted.first
  end
end

class CloudflareClientR2Test < ActiveSupport::TestCase
  # Reuse the write-seam fake (records patch/post/put/delete, GET from responses).
  FakeHttp = CloudflareClientWriteTest::FakeHttp
  ACCT = "acct1".freeze

  test "r2_buckets unwraps the result.buckets array" do
    http = FakeHttp.new("/accounts/#{ACCT}/r2/buckets" => {
      "success" => true, "result" => { "buckets" => [ { "name" => "calm-page-storage", "location" => "OC" } ] }
    })
    res = CloudflareClient.new("t", http: http).r2_buckets(ACCT)
    assert res.ok?
    assert_equal "calm-page-storage", res.data.first["name"]
  end

  test "r2_bucket returns the bucket metadata" do
    http = FakeHttp.new("/accounts/#{ACCT}/r2/buckets/calm-page-storage" => {
      "success" => true, "result" => { "name" => "calm-page-storage", "location" => "OC" }
    })
    res = CloudflareClient.new("t", http: http).r2_bucket(ACCT, "calm-page-storage")
    assert res.ok?
    assert_equal "OC", res.data["location"]
  end

  test "create_r2_bucket POSTs name and locationHint" do
    http = FakeHttp.new({})
    res = CloudflareClient.new("t", http: http).create_r2_bucket(ACCT, "calm-page-storage", location_hint: "eeur")
    assert res.ok?
    assert_equal "/accounts/#{ACCT}/r2/buckets", http.posted.first[0]
    assert_equal({ name: "calm-page-storage", locationHint: "eeur" }, http.posted.first[1])
  end

  test "create_r2_bucket omits locationHint when not given" do
    http = FakeHttp.new({})
    CloudflareClient.new("t", http: http).create_r2_bucket(ACCT, "b")
    assert_equal({ name: "b" }, http.posted.first[1])
  end

  test "delete_r2_bucket DELETEs the bucket path" do
    http = FakeHttp.new({})
    res = CloudflareClient.new("t", http: http).delete_r2_bucket(ACCT, "calm-page-storage")
    assert res.ok?
    assert_equal "/accounts/#{ACCT}/r2/buckets/calm-page-storage", http.deleted.first
  end

  test "put_r2_cors PUTs the rules wrapped under :rules" do
    http = FakeHttp.new({})
    rules = [ { allowed: { origins: [ "https://calm.page" ], methods: [ "GET", "PUT" ], headers: [ "*" ] }, maxAgeSeconds: 3600 } ]
    res = CloudflareClient.new("t", http: http).put_r2_cors(ACCT, "calm-page-storage", rules)
    assert res.ok?
    assert_equal "/accounts/#{ACCT}/r2/buckets/calm-page-storage/cors", http.putted.first[0]
    assert_equal({ rules: rules }, http.putted.first[1])
  end

  test "r2_cors unwraps result.rules" do
    http = FakeHttp.new("/accounts/#{ACCT}/r2/buckets/b/cors" => {
      "success" => true, "result" => { "rules" => [ { "allowed" => { "origins" => [ "https://calm.page" ] } } ] }
    })
    res = CloudflareClient.new("t", http: http).r2_cors(ACCT, "b")
    assert res.ok?
    assert_equal [ "https://calm.page" ], res.data.first.dig("allowed", "origins")
  end

  test "create_r2_custom_domain POSTs domain, zoneId and enabled" do
    http = FakeHttp.new({})
    res = CloudflareClient.new("t", http: http)
      .create_r2_custom_domain(ACCT, "calm-page-storage", domain: "assets.calm.page", zone_id: "z9")
    assert res.ok?
    assert_equal "/accounts/#{ACCT}/r2/buckets/calm-page-storage/domains/custom", http.posted.first[0]
    assert_equal({ domain: "assets.calm.page", zoneId: "z9", enabled: true }, http.posted.first[1])
  end

  test "r2 write surfaces an auth error from a read-only token" do
    http = FakeHttp.new("/accounts/#{ACCT}/r2/buckets/b/cors" =>
      { "success" => false, "errors" => [ { "message" => "Authentication error" } ] })
    # put path is not in responses, so simulate failure via a responses-backed put
    failing = Class.new(FakeHttp) do
      def put(path, body) = { "success" => false, "errors" => [ { "message" => "Authentication error" } ] }
    end.new({})
    res = CloudflareClient.new("t", http: failing).put_r2_cors(ACCT, "b", [])
    refute res.ok?
    assert_match(/Authentication error/, res.error)
  end
end
