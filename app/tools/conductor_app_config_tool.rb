# Consolidated app-config tool: flat `action` enum delegating via EnumDispatch.
# Kept separate from conductor_app so each tool's param union stays small.
class ConductorAppConfigTool
  include EnumDispatch

  ACTIONS = {
    "set_env"        => SetEnvVariableTool,
    "gen_deploy_key" => GenerateDeployKeyTool
  }.freeze

  DEFINITION = {
    name: "conductor_app_config",
    description: "App configuration. Set `action` to one of: " \
      "set_env (create/update an env var on an app — app_id/app_name, key, value, optional secret), " \
      "gen_deploy_key (generate a read-only SSH deploy key for the app's private repo — app_id/app_name).",
    input_schema: {
      type: "object",
      properties: {
        action:            { type: "string", enum: %w[set_env gen_deploy_key], description: "Which config operation" },
        app_id:            { type: "integer", description: "target app by id" },
        app_name:          { type: "string",  description: "target app by name" },
        key:               { type: "string",  description: "set_env: variable name (UPPER_SNAKE_CASE)" },
        value:             { type: "string",  description: "set_env: variable value" },
        secret:            { type: "boolean", description: "set_env: mark the value secret (masked in UI)" },
        organization_slug: { type: "string",  description: "set_env: org slug fallback when the app is unscoped" },
        organization_id:   { type: "integer", description: "set_env: org id fallback (overrides slug)" }
      },
      required: %w[action]
    }
  }.freeze
end
