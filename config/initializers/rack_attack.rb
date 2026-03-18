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

# Block suspicious requests
Rack::Attack.blocklist("block bad paths") do |req|
  req.path.match?(/\.(php|asp|aspx|cgi|env)$/i)
end

ActiveSupport::Notifications.subscribe("throttle.rack_attack") do |_name, _start, _finish, _id, payload|
  Rails.logger.warn("[Rack::Attack] Throttled #{payload[:request].ip} on #{payload[:request].path}")
end
