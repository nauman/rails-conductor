# Consolidated read tool. One flat tool with an `action` enum that dispatches
# to the existing single-purpose implementation classes, reusing their logic
# rather than duplicating it. Params are flat and permissive; the action picks
# the handler and the rest of the input passes straight through (each handler
# ignores params it doesn't use). Read-only by construction.
class ConductorReadTool
  include EnumDispatch

  ACTIONS = {
    "fleet_status" => FleetStatusTool,
    "logs"         => RecentLogsTool,
    "deployment"   => DeploymentLogTool
  }.freeze

  DEFINITION = {
    name: "conductor_read",
    description: "Read-only fleet visibility. Set `action` to one of: " \
      "fleet_status (all servers + their apps/health), " \
      "logs (recent script-run/deployment logs — server_id, script_run_id, limit), " \
      "deployment (one deployment's status + log — deployment_id, app_id, app_name, tail). " \
      "Call this before any mutating action to pick the server/app and confirm health.",
    input_schema: {
      type: "object",
      properties: {
        action:          { type: "string", enum: %w[fleet_status logs deployment], description: "Which read to perform" },
        organization_id: { type: "integer", description: "Optional org scope (fleet_status, logs)" },
        server_id:       { type: "integer", description: "logs: filter by server" },
        script_run_id:   { type: "integer", description: "logs: a specific script run" },
        limit:           { type: "integer", description: "logs: number of recent runs (default 5, max 20)" },
        deployment_id:   { type: "integer", description: "deployment: a specific deployment" },
        app_id:          { type: "integer", description: "deployment: app's latest deployment" },
        app_name:        { type: "string",  description: "deployment: app's latest deployment" },
        tail:            { type: "integer", description: "deployment: only the last N log lines" }
      },
      required: %w[action]
    }
  }.freeze
end
