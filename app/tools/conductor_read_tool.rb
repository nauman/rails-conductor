# Consolidated read tool. One flat tool with an `action` enum that dispatches
# to the existing single-purpose implementation classes, reusing their logic
# rather than duplicating it. Params are flat and permissive; the action picks
# the handler and the rest of the input passes straight through (each handler
# ignores params it doesn't use). Read-only by construction.
class ConductorReadTool
  include EnumDispatch

  ACTIONS = {
    "fleet_status" => FleetStatusTool,
    "server"       => ServerDetailTool,
    "situation"    => FleetSituationTool,
    "logs"         => RecentLogsTool,
    "app_logs"     => AppLogsTool,
    "deployment"   => DeploymentLogTool,
    "transfer"     => TransferStatusTool,
    "cloudflare"   => CloudflareStatusTool
  }.freeze

  DEFINITION = {
    name: "conductor_read",
    description: "Read-only fleet visibility. Set `action` to one of: " \
      "fleet_status (all servers + their apps/health, incl. cpu_percent (utilisation) + cpu_cores (physical, nil if unread)/memory/disk/load/uptime), " \
      "server (ONE server's detail — metrics, stored audit/update/harden rollups, cron jobs, ssh + edge, apps. server_id/server_name. Fast by default; pass probe:true to ALSO run live SSH probes for the deep panels — health, audit checks, storage, privileged-ops readiness — under a `live` key, slower and can time out on a loaded box), " \
      "situation (RESUME point — in-flight ops, needs-attention worklist, `subjects` (per-app: the ritual its shape resolves to, checklist progress, last run, and whether an operator customised it), recent events; call first on reconnect), " \
      "logs (recent script-run/deployment logs — server_id, script_run_id, limit — Conductor's OWN record of an operation, NOT what the app said), " \
      "app_logs (what the RUNNING app said. Goes through `kamal app logs` when the app has a kamal config — release- and role-aware — and falls back to docker otherwise; the reply says which via `via`. app_id/app_name, optional tail (default 200, max 2000). Use this to diagnose a live incident instead of SSHing. The reply carries `covers_from`: a container log is a rotating buffer, so an empty window may have been overwritten rather than quiet — if covers_from is later than the moment you care about, the evidence is gone, raise the app's log retention), " \
      "deployment (one deployment's status + log — deployment_id, app_id, app_name, tail), " \
      "transfer (an app-transfer's phase/status/error — transfer_id, or app_id/app_name for its latest, or omit to list recent transfers), " \
      "cloudflare (Cloudflare integration: connected accounts, owned zones, read-only MCP attach commands, proxyable apps, how to proxy a domain). " \
      "Call this before any mutating action to pick the server/app and confirm health.",
    input_schema: {
      type: "object",
      properties: {
        action:          { type: "string", enum: %w[fleet_status server situation logs app_logs deployment transfer cloudflare], description: "Which read to perform" },
        server_name:     { type: "string",  description: "server: target server by name" },
        probe:           { type: "boolean", description: "server: also run live SSH probes (health/audit/storage/sudo) under `live`. Default false (fast, stored-only); true is slower + can time out on a loaded box" },
        transfer_id:     { type: "integer", description: "transfer: a specific app-transfer by id" },
        recent_limit:    { type: "integer", description: "situation: recent terminal deployments to include (default 8, max 25)" },
        organization_id: { type: "integer", description: "Optional org scope (fleet_status, logs)" },
        server_id:       { type: "integer", description: "logs: filter by server" },
        script_run_id:   { type: "integer", description: "logs: a specific script run" },
        limit:           { type: "integer", description: "logs: number of recent runs (default 5, max 20)" },
        deployment_id:   { type: "integer", description: "deployment: a specific deployment" },
        app_id:          { type: "integer", description: "deployment/app_logs: target app by id" },
        app_name:        { type: "string",  description: "deployment/app_logs: target app by name" },
        tail:            { type: "integer", description: "deployment/app_logs: only the last N log lines" }
      },
      required: %w[action]
    }
  }.freeze
end
