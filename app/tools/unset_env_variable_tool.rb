# Remove an environment variable from an app. The inverse of SetEnvVariableTool.
# Idempotent: removing an absent key succeeds with deleted:false so callers (and
# the model) never have to pre-check existence. Dropping a derived-secret key
# (e.g. a manual DATABASE_URL on a dedicated app) is the supported way to let
# Conductor's derived value take over — App#derived_database_url yields once no
# manual DATABASE_URL env var remains.
class UnsetEnvVariableTool
  include ActorScoped

  include OrgResolvable

  DEFINITION = {
    name: "unset_env_variable",
    description: "Remove an environment variable from an app (idempotent).",
    input_schema: {
      type: "object",
      properties: {
        app_id:   { type: "integer", description: "App id (or use app_name)" },
        app_name: { type: "string",  description: "App name (or use app_id)" },
        key:      { type: "string",  description: "Variable name to remove (UPPER_SNAKE_CASE)" }
      },
      required: [ "key" ]
    }
  }.freeze

  def initialize(user:)
    @user = user
  end

  def call(input)
    app = find_app(input)
    return Result.fail("App not found: #{input['app_id'] || input['app_name']}") unless app

    key = input["key"].to_s
    return Result.fail("Missing required param: key") if key.blank?

    org = app.organization || resolve_organization(input).first
    var = app.env_variables.find_by(key: key)

    unless var
      return Result.ok({
        app_id:        app.id,
        app:           app.name,
        key:           key,
        deleted:       false,
        message:       "No environment variable #{key} on #{app.name} (nothing to remove).",
        _organization: org
      })
    end

    was_secret = var.secret
    var.destroy

    Result.ok({
      app_id:        app.id,
      app:           app.name,
      key:           key,
      deleted:       true,
      secret:        was_secret,
      message:       "Environment variable #{key} removed from #{app.name}.",
      _organization: org
    })
  end

  private
end
