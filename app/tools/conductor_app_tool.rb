# Consolidated app lifecycle tool: one flat `action` enum delegating via
# EnumDispatch to the single-purpose implementation classes.
class ConductorAppTool
  include EnumDispatch

  ACTIONS = {
    "create"      => CreateAppTool,
    "update"      => UpdateAppTool,
    "deploy"      => DeployAppTool,
    "rollback"    => RollbackAppTool,
    "sync_status" => SyncAppStatusTool
  }.freeze

  DEFINITION = {
    name: "conductor_app",
    description: "App lifecycle. Set `action` to one of: " \
      "create (new app — needs name, repository_url, deploy_method; optional server, domain, port, branch, notes), " \
      "update (change an existing app's config — app_id/app_name + any of deploy_method, repository_url, branch, domain, port, notes), " \
      "deploy (deploy an app to the latest commit on origin/<branch> — the REMOTE, not any local checkout; PUSH FIRST, unpushed commits are not shipped. app_id/app_name; the result reports ships_from + a verify pointer and records the resolved commit_sha. Runs a preflight that BLOCKS on an at-risk server audit, a deploy hold, or a failed seed run, returning status 'blocked' with the blockers — pass force:true to override. NB: the migration row is a capability label — whether a post-deploy migrate gate exists — NOT a pending-migration/drift probe, so it never blocks), " \
      "rollback (Kamal only: boot a previously-shipped release again — app_id/app_name + optional deployment_id; omit deployment_id to roll back to the release before the current one. No rebuild — reboots the prior image Kamal retains on the host), " \
      "sync_status (check live container status over SSH — app_id/app_name). " \
      "deploy and rollback are destructive/outward-facing — confirm with the user first.",
    input_schema: {
      type: "object",
      properties: {
        action:            { type: "string", enum: %w[create update deploy rollback sync_status], description: "Which app operation" },
        deployment_id:     { type: "integer", description: "rollback: the prior deployment whose release to roll back to (omit for the release before current)" },
        force:             { type: "boolean", description: "deploy: override a blocking preflight (at-risk audit / deploy hold). Confirm with the user first." },
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
        deploy_hold:       { type: "boolean", description: "update: hold deploys (preflight blocks) while a thread is owed; false clears" },
        deploy_hold_reason:{ type: "string",  description: "update: why the deploy is held (shown in the preflight block)" },
        seed_on_next_deploy:{ type: "boolean", description: "update: one-shot — run db:seed on the next deploy + record it to the seed ledger, then auto-clear" },
        organization_slug: { type: "string",  description: "create: org slug (defaults to actor's first org)" },
        organization_id:   { type: "integer", description: "create: org id (overrides organization_slug)" }
      },
      required: %w[action]
    }
  }.freeze
end
