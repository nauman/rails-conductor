require "test_helper"

class CloudflarePurgeTest < ActiveSupport::TestCase
  # A CloudflareClient stub recording the purge it received.
  class FakeClient
    attr_reader :purged
    def purge_cache(zone, files:) = (@purged = [ zone, files ]; CloudflareClient::Result.new(ok: true, data: {}))
  end

  setup do
    user = User.create!(email: "purge@example.com")
    @org = Organization.create_for(user, name: "Acme")
    @cred = @org.credentials.create!(name: "inventlist", provider: "cloudflare", api_key: "tok",
                                     zones: [ { "id" => "z1", "name" => "calm.page", "account_id" => "a" } ].to_json,
                                     account_id: "a", verified_at: Time.current)
    @app = @org.apps.create!(name: "Calm", slug: "calm", deploy_method: "kamal",
                             repository_url: "https://github.com/x/y.git", domain: "calm.page")
  end

  test "purges everything for the owning zone" do
    fake = FakeClient.new
    res = CloudflarePurge.new(@app, client_for: ->(_c) { fake }).purge!
    assert res.ok?, res.message
    assert_equal [ "z1", nil ], fake.purged
    assert_match(/Purged Cloudflare cache \(everything\) for calm.page/, res.message)
  end

  test "purges specific files" do
    fake = FakeClient.new
    res = CloudflarePurge.new(@app, client_for: ->(_c) { fake }).purge!(files: [ "https://calm.page/a.css" ])
    assert res.ok?
    assert_equal [ "z1", [ "https://calm.page/a.css" ] ], fake.purged
    assert_match(/1 URL/, res.message)
  end

  test "a subdomain resolves to the parent zone" do
    @app.update!(domain: "www.calm.page")
    fake = FakeClient.new
    assert CloudflarePurge.new(@app, client_for: ->(_c) { fake }).purge!.ok?
    assert_equal "z1", fake.purged.first
  end

  test "fails clearly when no connected account owns the domain" do
    @app.update!(domain: "unrelated.com")
    res = CloudflarePurge.new(@app, client_for: ->(_c) { FakeClient.new }).purge!
    refute res.ok?
    assert_match(/No connected Cloudflare account owns/, res.message)
  end

  test "fails clearly when the app has no domain" do
    @app.update_column(:domain, nil)
    res = CloudflarePurge.new(@app, client_for: ->(_c) { FakeClient.new }).purge!
    refute res.ok?
    assert_match(/no domain/i, res.message)
  end
end
