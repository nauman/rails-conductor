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

  test "verify surfaces the Cloudflare error when neither the token endpoint nor zones work" do
    http = FakeHttp.new(
      "/user/tokens/verify" => { "success" => false, "errors" => [ { "message" => "Invalid API Token" } ] },
      "/zones?per_page=50&page=1"  => { "success" => false, "errors" => [ { "message" => "Invalid API Token" } ] }
    )
    res = CloudflareClient.new("bad", http: http).verify
    refute res.ok?
    assert_match(/Invalid API Token/, res.error)
  end

  # An account-owned token is rejected by the user-scoped /user/tokens/verify but is
  # perfectly valid for zone ops — verify must fall back to a zones probe and report
  # it live, so Conductor never misreports a working account token as invalid.
  test "verify falls back to a zones probe for an account-owned token" do
    http = FakeHttp.new(
      "/user/tokens/verify" => { "success" => false, "errors" => [ { "message" => "Invalid API Token" } ] },
      "/zones?per_page=50&page=1"  => { "success" => true, "result" => [ { "id" => "z1", "name" => "rubyonrails.link", "account" => { "id" => "acct1" } } ] }
    )
    res = CloudflareClient.new("account-token", http: http).verify
    assert res.ok?, "an account token that can list zones must verify as live"
    assert_equal 1, res.data["zones"]
    assert_equal "account", res.data["scope"]
  end

  test "zones returns id/name/account_id triples" do
    http = FakeHttp.new("/zones?per_page=50&page=1" => {
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
    http = FakeHttp.new("/zones/z1/dns_records?name=old.x.com&type=A" => { "success" => true, "result" => [] })
    res = CloudflareClient.new("t", http: http).upsert_dns_record("z1", name: "old.x.com", content: "1.2.3.4")
    assert res.ok?
    assert_equal "/zones/z1/dns_records", http.posted.first[0]
    assert_equal({ type: "A", name: "old.x.com", content: "1.2.3.4", proxied: false, ttl: 1 }, http.posted.first[1])
  end

  # P1 regression (codex audit): a name with an existing TXT record must NOT be
  # rewritten — the lookup is scoped to the requested type, so upsert POSTs a new
  # A record and leaves the TXT untouched.
  test "upsert_dns_record ignores a different-type record at the same name (no rewrite)" do
    http = FakeHttp.new("/zones/z1/dns_records?name=old.x.com&type=A" => { "success" => true, "result" => [] })
    CloudflareClient.new("t", http: http).upsert_dns_record("z1", name: "old.x.com", content: "1.2.3.4", type: "A")
    assert_equal "/zones/z1/dns_records", http.posted.first[0], "should POST a new A, not PATCH the TXT"
    assert_empty http.patched
  end

  test "upsert_dns_record PATCHes the existing record when one is present" do
    http = FakeHttp.new("/zones/z1/dns_records?name=old.x.com&type=A" => { "success" => true, "result" => [ { "id" => "rec9" } ] })
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

  # PAGINATION. `?per_page=50` with no page walk silently truncates at 50 zones, and
  # a truncated list is indistinguishable from a complete one — the same shape as
  # the stale cache this pairs with: Conductor reports a zone as absent when it is
  # merely unseen. One account was already at 28 of 50.
  test "zones walks every page, not just the first" do
    page1 = { "success" => true,
              "result" => (1..50).map { |i| { "id" => "z#{i}", "name" => "z#{i}.test", "account" => { "id" => "acct" } } },
              "result_info" => { "page" => 1, "total_pages" => 2 } }
    page2 = { "success" => true,
              "result" => [ { "id" => "z51", "name" => "late-addition.test", "account" => { "id" => "acct" } } ],
              "result_info" => { "page" => 2, "total_pages" => 2 } }
    http = FakeHttp.new("/zones?per_page=50&page=1" => page1, "/zones?per_page=50&page=2" => page2)

    res = CloudflareClient.new("tok", http: http).zones

    assert res.ok?
    assert_equal 51, res.data.length
    assert_includes res.data.map { |z| z["name"] }, "late-addition.test",
                    "a zone past the first page must not be invisible"
  end

  test "a single page stops after one request" do
    body = { "success" => true,
             "result" => [ { "id" => "z1", "name" => "only.test", "account" => { "id" => "acct" } } ],
             "result_info" => { "page" => 1, "total_pages" => 1 } }
    http = FakeHttp.new("/zones?per_page=50&page=1" => body)

    res = CloudflareClient.new("tok", http: http).zones

    assert res.ok?
    assert_equal [ "only.test" ], res.data.map { |z| z["name"] }
  end

  # Cloudflare omits result_info on some responses. Missing pagination metadata must
  # mean "one page", never an unbounded loop against a live API.
  test "absent pagination metadata is treated as a single page" do
    body = { "success" => true, "result" => [ { "id" => "z1", "name" => "a.test", "account" => { "id" => "x" } } ] }
    http = FakeHttp.new("/zones?per_page=50&page=1" => body)

    assert_equal 1, CloudflareClient.new("tok", http: http).zones.data.length
  end

  # PAGE_LIMIT returning SUCCESS at the cap is the original truncation bug moved to a
  # bigger number: a partial list is indistinguishable from a complete one, and it
  # would then be cached over a good one. Hitting the cap must FAIL so the previous
  # cache survives.
  test "hitting the page limit fails rather than caching a partial list" do
    responses = {}
    (1..CloudflareClient::PAGE_LIMIT).each do |n|
      responses["/zones?per_page=50&page=#{n}"] = {
        "success" => true,
        "result" => [ { "id" => "z#{n}", "name" => "z#{n}.test", "account" => { "id" => "a" } } ],
        "result_info" => { "page" => n, "total_pages" => CloudflareClient::PAGE_LIMIT + 5 }
      }
    end

    res = CloudflareClient.new("tok", http: FakeHttp.new(responses)).zones

    assert_not res.ok?, "a truncated walk must not look like a complete one"
    assert_match(/page/i, res.error)
  end

  # Cloudflare can repeat or shift pages while zones are being added. Duplicates
  # would inflate the count and could mask a removal.
  test "zones are de-duplicated by id across pages" do
    dup = { "id" => "same", "name" => "same.test", "account" => { "id" => "a" } }
    http = FakeHttp.new(
      "/zones?per_page=50&page=1" => { "success" => true, "result" => [ dup ], "result_info" => { "page" => 1, "total_pages" => 2 } },
      "/zones?per_page=50&page=2" => { "success" => true, "result" => [ dup ], "result_info" => { "page" => 2, "total_pages" => 2 } }
    )

    assert_equal 1, CloudflareClient.new("tok", http: http).zones.data.length
  end
end
