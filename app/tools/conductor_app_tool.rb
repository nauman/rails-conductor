# Consolidated app lifecycle tool: one flat `action` enum delegating via
# EnumDispatch to the single-purpose implementation classes.
class ConductorAppTool
  include EnumDispatch

  ACTIONS = {
    "create"      => CreateAppTool,
    "update"      => UpdateAppTool,
    "deploy"      => DeployAppTool,
    "sync_status" => SyncAppStatusTool
  }.freeze

  DEFINITION = {
    name: "conductor_app",
    description: "App lifecycle. Set `action` to one of: " \
      "create (new app — needs name, repository_url, deploy_method; optional server, domain, port, branch, notes), " \
      "update (change an existing app's config — app_id/app_name + any of deploy_method, repository_url, branch, domain, port, notes), " \
      "deploy (deploy an app to its latest commit — app_id/app_name), " \
      "sync_status (check live container status over SSH — app_id/app_name). " \
      "deploy is destructive/outward-facing — confirm with the user first.",
    input_schema: {
      type: "object",
      properties: {
        action:            { type: "string", enum: %w[create update deploy sync_status], description: "Which app operation" },
        app_id:            { type: "integer", description: "update/deploy/sync_status: target app by id" },
        app_name:          { type: "string",  description: "update/deploy/sync_status: target app by name" },
        name:              { type: "string",  description: "create: app name" },
        repository_url:    { type: "string",  description: "create/update: git repository URL" },
        deploy_method:     { type: "string",  enum: %w[docker native kamal], description: "create (docker|native) / update (docker|native|kamal)" },
        server_id:         { type: "integer", description: "create: server to deploy to (or server_name)" },
        server_name:       { type: "string",  description: "create: server to deploy to (or server_id)" },
        domain:            { type: "string",  description: "create/update: public domain" },
        port:              { type: "integer", description: "create/update: app port" },
        branch:            { type: "string",  description: "create/update: git branch (default main)" },
        notes:             { type: "string",  description: "create/update: free-form deploy notes" },
        organization_slug: { type: "string",  description: "create: org slug (defaults to actor's first org)" },
        organization_id:   { type: "integer", description: "create: org id (overrides organization_slug)" }
      },
      required: %w[action]
    }
  }.freeze
end
