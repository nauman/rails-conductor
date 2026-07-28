require "test_helper"

class SesClientTest < ActiveSupport::TestCase
  test "verify succeeds when SMTP auth accepts the creds; derives the regional host" do
    seen = nil
    auth = ->(host, user, pass) { seen = [ host, user, pass ] } # no raise = accepted
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

  # Regression (found in production, calm.page 2026-07-28): the real authenticator
  # used the block form of Net::SMTP#start — which closes the session itself — and
  # then called #finish, so every verify raised IOError("not yet started") and was
  # reported as a failure even when the AUTH had succeeded. Every other test here
  # injects `authenticator:`, so none of them touched that code.
  #
  # This double stands in for Net::SMTP and enforces the same rule: #finish on a
  # closed session raises.
  class FakeSmtp
    attr_reader :started_with
    attr_writer :open_timeout, :read_timeout

    def initialize
      @open = false
    end

    def enable_starttls_auto
      nil
    end

    def start(domain, user, pass, auth)
      @started_with = [ domain, user, pass, auth ]
      @open = true
      return self unless block_given?

      begin
        yield self
      ensure
        @open = false # the block form closes the session
      end
    end

    def finish
      raise IOError, "not yet started" unless @open

      @open = false
    end
  end

  test "the real SMTP authenticator reports success when AUTH is accepted" do
    fake = FakeSmtp.new
    Net::SMTP.stub(:new, fake) do
      result = SesClient.new("USER", "PASS", "ap-southeast-2").verify
      assert result.ok?, "a successful AUTH must not be reported as a failure: #{result.error}"
    end
    assert_equal [ "conductor", "USER", "PASS", :login ], fake.started_with
  end
end
