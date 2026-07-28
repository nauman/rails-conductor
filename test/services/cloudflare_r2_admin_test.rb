require "test_helper"

class CloudflareR2AdminTest < ActiveSupport::TestCase
  # CloudflareClient stub recording the R2 admin calls it received.
  class FakeClient
    attr_reader :cors, :domains
    attr_accessor :existing_rules
    def initialize = (@cors = []; @domains = []; @existing_rules = [])
    def r2_cors(_account_id, _bucket)
      CloudflareClient::Result.new(ok: true, data: @existing_rules)
    end
    def put_r2_cors(account_id, bucket, rules)
      @cors << [ account_id, bucket, rules ]
      CloudflareClient::Result.new(ok: true, data: {})
    end
    def create_r2_custom_domain(account_id, bucket, domain:, zone_id:)
      @domains << [ account_id, bucket, domain, zone_id ]
      CloudflareClient::Result.new(ok: true, data: {})
    end
  end

  setup do
    user = User.create!(email: "r2admin@example.com")
    @org = Organization.create_for(user, name: "Acme")
    @cred = @org.credentials.create!(name: "inventlist", provider: "cloudflare", api_key: "tok",
                                     zones: [ { "id" => "z1", "name" => "calm.page", "account_id" => "acct1" } ].to_json,
                                     account_id: "acct1", verified_at: Time.current)
  end

  test "set_cors resolves the owning account and PUTs the rule" do
    fake = FakeClient.new
    res = CloudflareR2Admin.new(@org, client_for: ->(_c) { fake })
      .set_cors("calm-page-storage", account_domain: "calm.page", origins: [ "https://calm.page", "https://*.calm.page" ])
    assert res.ok?, res.message
    account_id, bucket, rules = fake.cors.first
    assert_equal "acct1", account_id
    assert_equal "calm-page-storage", bucket
    assert_equal [ "https://calm.page", "https://*.calm.page" ], rules.first[:allowed][:origins]
    assert_equal %w[GET PUT], rules.first[:allowed][:methods]
  end

  test "connect_domain resolves the zone by the custom subdomain and POSTs it" do
    fake = FakeClient.new
    res = CloudflareR2Admin.new(@org, client_for: ->(_c) { fake })
      .connect_domain("calm-page-storage", "assets.calm.page")
    assert res.ok?, res.message
    account_id, bucket, domain, zone_id = fake.domains.first
    assert_equal "acct1", account_id
    assert_equal "calm-page-storage", bucket
    assert_equal "assets.calm.page", domain
    assert_equal "z1", zone_id
  end

  test "set_cors fails clearly when no connected account owns the domain" do
    res = CloudflareR2Admin.new(@org, client_for: ->(_c) { FakeClient.new })
      .set_cors("b", account_domain: "unrelated.com", origins: [ "https://unrelated.com" ])
    refute res.ok?
    assert_match(/No connected Cloudflare account owns/, res.message)
  end

  test "surfaces a Cloudflare auth error verbatim (read-only token)" do
    denier = Object.new
    denier.define_singleton_method(:r2_cors) { |*| CloudflareClient::Result.new(ok: true, data: []) }
    denier.define_singleton_method(:put_r2_cors) { |*| CloudflareClient::Result.new(ok: false, error: "Authentication error") }
    res = CloudflareR2Admin.new(@org, client_for: ->(_c) { denier })
      .set_cors("calm-page-storage", account_domain: "calm.page", origins: [ "https://calm.page" ])
    refute res.ok?
    assert_match(/Authentication error/, res.message)
  end

  test "refuses a bucket already claimed by another org on the same account (finding 1)" do
    other = Organization.create_for(User.create!(email: "other@example.com"), name: "Other")
    StorageBucket.create!(organization: other, name: "calm-page-storage", cloudflare_account_id: "acct1")

    res = CloudflareR2Admin.new(@org, client_for: ->(_c) { FakeClient.new })
      .set_cors("calm-page-storage", account_domain: "calm.page", origins: [ "https://calm.page" ])

    refute res.ok?
    assert_match(/belongs to another organization/, res.message)
  end

  test "set_cors is read-modify-write — preserves another app's rule, replaces only ours (finding 3)" do
    fake = FakeClient.new
    fake.existing_rules = [ { "id" => "conductor-other", "allowed" => { "origins" => [ "https://other.app" ] } } ]

    res = CloudflareR2Admin.new(@org, client_for: ->(_c) { fake })
      .set_cors("calm-page-storage", account_domain: "calm.page", origins: [ "https://calm.page" ], rule_id: "conductor-calm")
    assert res.ok?, res.message

    _account, _bucket, put_rules = fake.cors.first
    ids = put_rules.map { |r| r[:id] || r["id"] }
    assert_includes ids, "conductor-other", "the other app's rule survives"
    assert_includes ids, "conductor-calm", "our rule is written"
    assert_equal 2, put_rules.size
    assert_equal 1, res.data[:preserved_rules]
  end

  test "set_cors replaces its OWN prior rule rather than stacking it" do
    fake = FakeClient.new
    fake.existing_rules = [ { "id" => "conductor-calm", "allowed" => { "origins" => [ "https://old" ] } } ]

    CloudflareR2Admin.new(@org, client_for: ->(_c) { fake })
      .set_cors("calm-page-storage", account_domain: "calm.page", origins: [ "https://new" ], rule_id: "conductor-calm")

    put_rules = fake.cors.first.last
    assert_equal 1, put_rules.size, "our stale rule is dropped, not duplicated"
    assert_equal [ "https://new" ], put_rules.first[:allowed][:origins]
  end
end
