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
    Result.new(ok: false, error: "#{e.message} (tried #{@host})#{auth_hint(e.message)}")
  end

  private

  # A 535 with valid-looking SMTP username/password almost always means the region is
  # wrong: SES SMTP passwords are derived per-region and only authenticate against the
  # region they were created in. Point at the fix instead of a bare "invalid".
  def auth_hint(message)
    return "" unless message.to_s.match?(/535|authentication credentials/i)

    ". If the SMTP username/password are correct, set this credential's Region to the " \
    "AWS region where the SMTP credentials were created (e.g. us-east-1, eu-west-1) — " \
    "SES SMTP passwords are region-specific."
  end

  # The block form of #start closes the connection itself when the block ends. Do
  # NOT call #finish afterwards: Net::SMTP#finish raises IOError("not yet started")
  # on an already-closed session, which verify would then report as a failure — even
  # though the AUTH succeeded. ("not yet started" in a verify error is the tell.)
  def smtp_auth(host, user, pass)
    smtp = Net::SMTP.new(host, PORT)
    smtp.enable_starttls_auto
    smtp.open_timeout = 10
    smtp.read_timeout = 10
    smtp.start("conductor", user, pass, :login) { } # raises on bad auth / connect
  end
end
