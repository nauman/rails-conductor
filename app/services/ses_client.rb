require "net/smtp"

# Amazon SES connection via the SMTP interface (what most SES email uses). Mirrors
# CloudflareClient: verify a connection with manual creds. Credentials: api_key = SMTP
# username, api_secret = SMTP password, region → host email-smtp.<region>.amazonaws.com
# (or an explicit endpoint override). Verify does a real STARTTLS + AUTH LOGIN — if the
# creds are wrong the SMTP server rejects the login, so it's a true credential check.
class SesClient
  Result = Struct.new(:ok, :data, :error, keyword_init: true) do
    def ok? = ok
  end

  PORT = 587

  def initialize(username, password, region, endpoint: nil, authenticator: nil)
    @username = username
    @password = password
    @region = region.presence || "us-east-1"
    @host = endpoint.presence || "email-smtp.#{@region}.amazonaws.com"
    @authenticator = authenticator || method(:smtp_auth) # injectable for tests
  end

  def verify
    @authenticator.call(@host, @username, @password)
    Result.new(ok: true, data: { "host" => @host, "region" => @region })
  rescue => e
    Result.new(ok: false, error: e.message)
  end

  private

  def smtp_auth(host, user, pass)
    smtp = Net::SMTP.new(host, PORT)
    smtp.enable_starttls_auto
    smtp.open_timeout = 10
    smtp.read_timeout = 10
    smtp.start("conductor", user, pass, :login) { } # raises on bad auth / connect
    smtp.finish
  end
end
