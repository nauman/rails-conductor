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

# Block suspicious requests
Rack::Attack.blocklist("block bad paths") do |req|
  req.path.match?(/\.(php|asp|aspx|cgi|env)$/i)
end

ActiveSupport::Notifications.subscribe("throttle.rack_attack") do |_name, _start, _finish, _id, payload|
  Rails.logger.warn("[Rack::Attack] Throttled #{payload[:request].ip} on #{payload[:request].path}")
end
