require "test_helper"

class CloudflareCutoverTest < ActiveSupport::TestCase
  # A CloudflareClient stub recording the calls it received.
  class FakeClient
    attr_reader :proxied_set, :ssl_set
    def dns_record(_zone, _name) = CloudflareClient::Result.new(ok: true, data: { "id" => "rec1", "proxied" => false })
    def set_proxied(_zone, rec, val) = (@proxied_set = [ rec, val ]; CloudflareClient::Result.new(ok: true, data: {}))
    def set_ssl_mode(_zone, mode) = (@ssl_set = mode; CloudflareClient::Result.new(ok: true, data: {}))
  end

  setup do
    user = User.create!(email: "cut@example.com")
    @org = Organization.create_for(user, name: "Acme")
    @cred = @org.credentials.create!(name: "inventlist", provider: "cloudflare", api_key: "tok",
                                     zones: [ { "id" => "z1", "name" => "calm.page", "account_id" => "a" } ].to_json,
                                     account_id: "a", verified_at: Time.current)
    @app = @org.apps.create!(name: "Calm", slug: "calm", deploy_method: "kamal",
                             repository_url: "https://github.com/x/y.git", domain: "calm.page")
  end

  test "resolves the owning account/zone, proxies the record, and sets SSL Full" do
    fake = FakeClient.new
    res = CloudflareCutover.new(@app, client_for: ->(_c) { fake }).put_behind!
    assert res.ok?, res.message
    assert_equal [ "rec1", true ], fake.proxied_set
    assert_equal "full", fake.ssl_set
    assert_match(/proxied through Cloudflare \(inventlist\)/, res.message)
  end

  test "a subdomain resolves to the parent zone" do
    @app.update!(domain: "www.calm.page")
    fake = FakeClient.new
    assert CloudflareCutover.new(@app, client_for: ->(_c) { fake }).put_behind!.ok?
  end

  test "fails clearly when no connected account owns the domain" do
    @app.update!(domain: "unrelated.com")
    res = CloudflareCutover.new(@app, client_for: ->(_c) { FakeClient.new }).put_behind!
    refute res.ok?
    assert_match(/No connected Cloudflare account owns/, res.message)
  end

  test "fails clearly when the domain has no DNS record" do
    no_rec = Object.new
    no_rec.define_singleton_method(:dns_record) { |*| CloudflareClient::Result.new(ok: true, data: nil) }
    res = CloudflareCutover.new(@app, client_for: ->(_c) { no_rec }).put_behind!
    refute res.ok?
    assert_match(/no DNS record/i, res.message)
  end
end
