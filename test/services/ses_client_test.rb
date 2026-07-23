require "test_helper"

class SesClientTest < ActiveSupport::TestCase
  test "verify succeeds when SMTP auth accepts the creds; derives the regional host" do
    seen = nil
    auth = ->(host, user, pass) { seen = [host, user, pass] } # no raise = accepted
    r = SesClient.new("USER", "PASS", "ap-southeast-2", authenticator: auth).verify
    assert r.ok?
    assert_equal [ "email-smtp.ap-southeast-2.amazonaws.com", "USER", "PASS" ], seen
    assert_equal "email-smtp.ap-southeast-2.amazonaws.com", r.data["host"]
  end

  test "verify surfaces the SMTP error on bad creds" do
    auth = ->(*) { raise Net::SMTPAuthenticationError.new("535 Authentication Credentials Invalid") }
    r = SesClient.new("U", "bad", "us-east-1", authenticator: auth).verify
    refute r.ok?
    assert_match(/Authentication/i, r.error)
  end

  test "an explicit endpoint overrides the regional host" do
    seen = nil
    SesClient.new("U", "P", "us-east-1", endpoint: "smtp.custom:587", authenticator: ->(h, *) { seen = h }).verify
    assert_equal "smtp.custom:587", seen
  end
end
