# Removes secret values from anything Conductor stores or broadcasts.
#
# WHY THIS DISTRUSTS THE APP. Conductor stored a live OAuth client secret in
# plaintext in a deployment log. The app had declared that key under kamal's
# `env: clear:` rather than `env: secret:`, so kamal inlined the value into the
# `docker run` command line, and KamalDeployer captured kamal's stdout verbatim.
#
# The tempting reading is "that app misconfigured itself". The useful reading is
# that a control plane held a credential it was never meant to see, because it
# trusted the app's own declaration about what was secret. AppDeployer already
# redacted using Conductor's record of secret keys — but a record-driven check
# cannot catch a key the record does not know about, which is exactly this case.
#
# So there are two independent grounds, and the second is the one that would have
# caught it:
#
#   1. Conductor RECORDS the key as secret (deploy_secret_keys)
#   2. The key merely LOOKS secret by name
#
# Rule 2 over-redacts by design. A log with a redacted bucket name is a mild
# nuisance; a log with a live credential is an incident, and this is not a
# symmetrical trade.
class SecretScrubber
  REDACTED = "[REDACTED]".freeze

  # Names that carry credentials often enough to redact on sight. Deliberately
  # broad — see the note above about which direction the errors should fall.
  SECRETISH = /(SECRET|TOKEN|PASSWORD|PASSWD|CREDENTIAL|PRIVATE_KEY|_KEY\z|APIKEY|API_KEY|DSN|DATABASE_URL|AUTH|SIGNATURE|SALT)/

  # `--env KEY=value`, `-e KEY=value`, and a bare `KEY=value` assignment. The value
  # may be quoted, shell-escaped, or bare; it ends at whitespace outside quotes.
  ASSIGNMENT = /(?<lead>(?:--env|-e)\s+|\A|\s)(?<key>[A-Z][A-Z0-9_]*)=(?<value>"[^"]*"|'[^']*'|\S+)/

  def initialize(app = nil)
    @app = app
  end

  def scrub(text)
    return text if text.nil? || text.empty?

    text.gsub(ASSIGNMENT) do
      m = Regexp.last_match
      secret?(m[:key]) ? "#{m[:lead]}#{m[:key]}=#{REDACTED}" : m[0]
    end
  end

  private

  def secret?(key)
    key.match?(SECRETISH) || recorded_secret_keys.include?(key)
  end

  # Never let a lookup failure turn into an unredacted log: an app that cannot be
  # read still gets rule 2, and rule 2 is the one that catches the misdeclared key.
  def recorded_secret_keys
    @recorded_secret_keys ||= begin
      @app&.deploy_secret_keys(server: @app.server).to_a.map(&:to_s)
    rescue StandardError
      []
    end
  end
end
