# Rack::Attack rate limiting and throttling configuration

Rack::Attack.throttle("requests/ip", limit: 300, period: 5.minutes) do |req|
  req.ip unless req.path.start_with?("/assets")
end

Rack::Attack.throttle("logins/ip", limit: 5, period: 20.seconds) do |req|
  req.ip if req.path.start_with?("/users/sign") && req.post?
end

Rack::Attack.throttle("api/ip", limit: 60, period: 1.minute) do |req|
  req.ip if req.path.start_with?("/api/")
end

# Dynamic client registration is unauthenticated by design (RFC 7591) — each POST
# creates an oauth_applications row, so cap it. A real client registers once and
# reuses the client_id.
Rack::Attack.throttle("oauth_register/ip", limit: 10, period: 1.hour) do |req|
  req.ip if req.path == "/oauth/register" && req.post?
end

# Open sign-up (plan 02 § 5.2, delegated defaults): 5 sign-up POSTs per IP per
# hour and 3 per email address per hour. The email is keyed by a digest, never
# stored in the cache in the clear. Verified sign-ups per /24 per day are counted
# in SignupIntent#consume!, where "verified" is actually known.
Rack::Attack.throttle("signup/ip", limit: 5, period: 1.hour) do |req|
  req.ip if req.path == "/signup" && req.post?
end

Rack::Attack.throttle("signup/email", limit: 3, period: 1.hour) do |req|
  if req.path == "/signup" && req.post?
    email = req.params["email"].to_s.strip.downcase
    SignupIntent.email_digest(email) if email.present?
  end
end

# Block suspicious requests
Rack::Attack.blocklist("block bad paths") do |req|
  req.path.match?(/\.(php|asp|aspx|cgi|env)$/i)
end

ActiveSupport::Notifications.subscribe("throttle.rack_attack") do |_name, _start, _finish, _id, payload|
  Rails.logger.warn("[Rack::Attack] Throttled #{payload[:request].ip} on #{payload[:request].path}")
end
