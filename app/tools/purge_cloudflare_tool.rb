# Purge an app's Cloudflare cache (everything, or specific URLs). Mutating —
# needs an operator/deploy-scoped token. Delegates to CloudflarePurge. Use after
# a deploy when the edge serves stale assets: Cloudflare caches even a 404 for a
# hashed CSS file (see docs/learnings/static-assets-404-behind-caddy.md).
class PurgeCloudflareTool
  include ActorScoped

  DEFINITION = {
    name: "purge_cloudflare",
    description: "Purge an app's Cloudflare edge cache. Pass files (array of full URLs) to purge specific assets, " \
      "or omit to purge everything. Requires a connected + Verified Cloudflare account (see conductor_read action=cloudflare) that owns the zone.",
    input_schema: {
      type: "object",
      properties: {
        app_id:   { type: "integer", description: "The app whose cache to purge" },
        app_name: { type: "string",  description: "The app whose cache to purge (alternative to app_id)" },
        files:    { type: "array", items: { type: "string" }, description: "Optional: specific full URLs to purge (omit = purge everything)" }
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

    files = input["files"].presence
    r = CloudflarePurge.new(app).purge!(files: files)
    return Result.fail(r.message) unless r.ok?

    Result.ok({
      app: app.name,
      domain: app.domain,
      purged: files || "everything",
      message: r.message,
      _organization: app.organization
    })
  end
end
