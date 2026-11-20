require "net/http"
require "json"

# Cloudflare Turnstile, the human check on the sign-up form (plan 02 § 5.2).
# Conductor serves the widget and verifies the token server-side; an agent never
# solves it.
#
#   TURNSTILE_SITE_KEY   — public, rendered into the form
#   TURNSTILE_SECRET_KEY — server-side verification
#
# Cloudflare publishes test keys that always pass (site 1x00000000000000000000AA,
# secret 1x0000000000000000000000000000000AA) and always fail (secret
# 2x0000000000000000000000000000000AA); development uses those.
#
# With no secret configured the check FAILS CLOSED in open mode: a public sign-up
# with the human check silently off is exactly the misconfiguration to refuse.
class Turnstile
  VERIFY_URL = URI("https://challenges.cloudflare.com/turnstile/v0/siteverify")

  def self.site_key = ENV["TURNSTILE_SITE_KEY"].presence
  def self.secret_key = ENV["TURNSTILE_SECRET_KEY"].presence
  def self.configured? = site_key.present? && secret_key.present?

  def initialize(http: nil)
    @http = http || method(:post_form)
  end

  def verify(token, remote_ip:)
    return false if token.blank? || !self.class.configured?

    body = @http.call(VERIFY_URL, "secret" => self.class.secret_key, "response" => token.to_s, "remoteip" => remote_ip.to_s)
    JSON.parse(body.to_s)["success"] == true
  rescue StandardError => e
    Rails.logger.warn("[turnstile] verification failed closed: #{e.class}: #{e.message}")
    false
  end

  private

  def post_form(uri, params)
    Net::HTTP.post_form(uri, params).body
  end
end
