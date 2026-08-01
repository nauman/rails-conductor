require "test_helper"

class CloudflareDnsRecordTest < ActiveSupport::TestCase
  # A CloudflareClient stub recording the calls it received.
  class FakeClient
    attr_reader :seen, :deleted
    attr_reader :deleted_ids
    def initialize(record: { "id" => "rec1" }, records: nil)
      @record = record
      @records = records
      @deleted_ids = []
    end
    def upsert_dns_record(zone, name:, content:, type:, proxied:)
      @seen = [ zone, name, content, type, proxied ]
      CloudflareClient::Result.new(ok: true, data: { "id" => "rec1", "name" => name })
    end
    def dns_record(_zone, _name, type: nil) = CloudflareClient::Result.new(ok: true, data: @record)
    def dns_records(_zone, _name, type: nil) = CloudflareClient::Result.new(ok: true, data: Array(@records || [ @record ].compact))
    def delete_dns_record(zone, id)
      @deleted = [ zone, id ]
      @deleted_ids << id
      CloudflareClient::Result.new(ok: true, data: {})
    end
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

  # TXT support exists so domain verification and email records — SPF, DKIM,
  # SES/Google identity tokens — stop requiring the Cloudflare dashboard.
  test "writes a TXT record" do
    client = FakeClient.new
    r = CloudflareDnsRecord.new(cf_creds, client_for: ->(_) { client })
                           .set!(domain: "google._domainkey.platepose.com",
                                 content: "v=DKIM1; k=rsa; p=MIIBIjANBg", type: "TXT")

    assert r.ok?, r.message
    _zone, name, content, type, proxied = client.seen
    assert_equal "google._domainkey.platepose.com", name
    assert_equal "TXT", type
    assert_equal "v=DKIM1; k=rsa; p=MIIBIjANBg", content
    assert_equal false, proxied
  end

  # Cloudflare rejects a proxied TXT; refusing here explains why instead of
  # forwarding a request that cannot succeed.
  test "refuses to proxy a TXT record" do
    r = CloudflareDnsRecord.new(cf_creds, client_for: ->(_) { FakeClient.new })
                           .set!(domain: "platepose.com", content: "v=spf1 -all",
                                 type: "TXT", proxied: true)

    assert_not r.ok?
    assert_match(/cannot be proxied/, r.message)
  end

  test "refuses an unsupported record type" do
    r = CloudflareDnsRecord.new(cf_creds, client_for: ->(_) { FakeClient.new })
                           .set!(domain: "platepose.com", content: "10 mx.example.com", type: "MX")

    assert_not r.ok?
    assert_match(/Unsupported record type MX/, r.message)
  end

  # A name can carry several records. Deleting only the first while reporting
  # success leaves it still resolving — a false success on a destructive action,
  # which is worse than failing, because the caller believes it is done.
  test "deletes EVERY record at the name, not just the first" do
    client = FakeClient.new(records: [ { "id" => "a1", "type" => "A" },
                                       { "id" => "a2", "type" => "A" },
                                       { "id" => "q1", "type" => "AAAA" } ])

    r = CloudflareDnsRecord.new(cf_creds, client_for: ->(_) { client }).delete!(domain: "platepose.com")

    assert r.ok?, r.message
    assert_equal %w[a1 a2 q1], client.deleted_ids, "every record must go"
    assert_match(/3 record\(s\)/, r.message)
    assert_match(/2×A/, r.message)
  end

  test "reports already-absent without claiming a deletion" do
    client = FakeClient.new(records: [])

    r = CloudflareDnsRecord.new(cf_creds, client_for: ->(_) { client }).delete!(domain: "platepose.com")

    assert r.ok?
    assert_empty client.deleted_ids
    assert_match(/already absent/, r.message)
  end
end
