require "test_helper"

class CloudflareDnsRecordTest < ActiveSupport::TestCase
  # A CloudflareClient stub recording the calls it received.
  class FakeClient
    attr_reader :seen, :deleted
    def initialize(record: { "id" => "rec1" }) = @record = record
    def upsert_dns_record(zone, name:, content:, type:, proxied:)
      @seen = [ zone, name, content, type, proxied ]
      CloudflareClient::Result.new(ok: true, data: { "id" => "rec1", "name" => name })
    end
    def dns_record(_zone, _name) = CloudflareClient::Result.new(ok: true, data: @record)
    def delete_dns_record(zone, id) = (@deleted = [ zone, id ]; CloudflareClient::Result.new(ok: true, data: {}))
  end

  setup do
    user = User.create!(email: "dns@example.com")
    @org = Organization.create_for(user, name: "Acme")
    @cred = @org.credentials.create!(name: "intellecta", provider: "cloudflare", api_key: "tok",
                                     zones: [ { "id" => "z1", "name" => "platepose.com", "account_id" => "a" } ].to_json,
                                     account_id: "a", verified_at: Time.current)
  end

  def cf_creds = Credential.where(provider: "cloudflare")

  test "upserts an A record in the owning (parent) zone" do
    fake = FakeClient.new
    res = CloudflareDnsRecord.new(cf_creds, client_for: ->(_c) { fake }).set!(domain: "old.platepose.com", content: "146.190.222.165")
    assert res.ok?, res.message
    assert_equal [ "z1", "old.platepose.com", "146.190.222.165", "A", false ], fake.seen
    assert_match(/A old.platepose.com → 146.190.222.165 set in Cloudflare \(intellecta\)/, res.message)
  end

  test "passes type + proxied through" do
    fake = FakeClient.new
    CloudflareDnsRecord.new(cf_creds, client_for: ->(_c) { fake }).set!(domain: "www.platepose.com", content: "platepose.com", type: "cname", proxied: true)
    assert_equal [ "z1", "www.platepose.com", "platepose.com", "CNAME", true ], fake.seen
  end

  test "fails clearly when no connected account owns the domain" do
    res = CloudflareDnsRecord.new(cf_creds, client_for: ->(_c) { FakeClient.new }).set!(domain: "unrelated.com", content: "1.1.1.1")
    refute res.ok?
    assert_match(/No connected Cloudflare account owns/, res.message)
  end

  test "requires domain and content" do
    refute CloudflareDnsRecord.new(cf_creds).set!(domain: "", content: "1.1.1.1").ok?
    refute CloudflareDnsRecord.new(cf_creds).set!(domain: "x.platepose.com", content: "").ok?
  end

  test "delete! removes the record in the owning zone" do
    fake = FakeClient.new(record: { "id" => "rec9" })
    res = CloudflareDnsRecord.new(cf_creds, client_for: ->(_c) { fake }).delete!(domain: "old.platepose.com")
    assert res.ok?, res.message
    assert_equal [ "z1", "rec9" ], fake.deleted
    assert_match(/Deleted old.platepose.com/, res.message)
  end

  test "delete! is idempotent when the record is already absent" do
    fake = FakeClient.new(record: nil)
    res = CloudflareDnsRecord.new(cf_creds, client_for: ->(_c) { fake }).delete!(domain: "gone.platepose.com")
    assert res.ok?
    assert_nil fake.deleted
    assert_match(/already absent/, res.message)
  end

  test "delete! fails when no connected account owns the domain" do
    res = CloudflareDnsRecord.new(cf_creds, client_for: ->(_c) { FakeClient.new }).delete!(domain: "unrelated.com")
    refute res.ok?
    assert_match(/No connected Cloudflare account owns/, res.message)
  end
end
