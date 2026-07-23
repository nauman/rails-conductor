# Put an app's domain behind Cloudflare: find the connected account that owns the
# zone, flip the DNS record to proxied (orange cloud), and set the zone SSL mode.
# Mutating — needs a deploy-scoped, operator token. Delegates to CloudflareCutover.
class PutBehindCloudflareTool
  include ActorScoped

  DEFINITION = {
    name: "put_behind_cloudflare",
    description: "Route an app's domain through Cloudflare's proxy (orange cloud) for CDN + edge TLS. " \
      "Requires a connected + Verified Cloudflare account (see conductor_read action=cloudflare) that owns the zone.",
    input_schema: {
      type: "object",
      properties: {
        app_id:   { type: "integer", description: "The app whose domain to proxy" },
        app_name: { type: "string",  description: "The app whose domain to proxy (alternative to app_id)" },
        ssl_mode: { type: "string",  description: "Zone SSL mode (default 'full' — safe with origin TLS). One of: off, flexible, full, strict" }
      },
      required: []
    }
  }.freeze

  def initialize(user:)
    @user = user
  end

  def call(input)
    app = find_app(input)
    return Result.fail("App not found. Pass a valid app_id or app_name.") unless app
    return Result.fail("#{app.name} has no domain set.") if app.domain.blank?

    ssl_mode = input["ssl_mode"].presence || "full"
    r = CloudflareCutover.new(app).put_behind!(ssl_mode: ssl_mode)
    return Result.fail(r.message) unless r.ok?

    Result.ok({
      app: app.name,
      domain: app.domain,
      ssl_mode: ssl_mode,
      message: r.message,
      _organization: app.organization
    })
  end
end
