# Consolidated app lifecycle tool: one flat `action` enum delegating via
# EnumDispatch to the single-purpose implementation classes.
class ConductorAppTool
  include EnumDispatch

  ACTIONS = {
    "create"      => CreateAppTool,
    "update"      => UpdateAppTool,
    "deploy"      => DeployAppTool,
    "rollback"    => RollbackAppTool,
    "sync_status" => SyncAppStatusTool,
    "cancel"      => CancelDeploymentAppTool,
    "convert_database" => ConvertDatabaseAppTool,
    "transfer_plan" => TransferPlanAppTool,
    "transfer"      => TransferAppTool
  }.freeze

  DEFINITION = {
    name: "conductor_app",
    description: "App lifecycle. Set `action` to one of: " \
      "create (new app — needs name, repository_url, deploy_method; optional server, domain, port, branch, notes), " \
      "update (change an existing app's config — app_id/app_name + any of deploy_method, repository_url, branch, domain, port, notes), " \
      "deploy (deploy an app to the latest commit on origin/<branch> — the REMOTE, not any local checkout; PUSH FIRST, unpushed commits are not shipped. app_id/app_name; the result reports ships_from + a verify pointer and records the resolved commit_sha. Runs a preflight that BLOCKS on an at-risk server audit, a deploy hold, or a failed seed run, returning status 'blocked' with the blockers — pass force:true to override. NB: the migration row is a capability label — whether a post-deploy migrate gate exists — NOT a pending-migration/drift probe, so it never blocks), " \
      "rollback (Kamal only: boot a previously-shipped release again — app_id/app_name + optional deployment_id; omit deployment_id to roll back to the release before the current one. No rebuild — reboots the prior image Kamal retains on the host), " \
      "sync_status (check live container status over SSH — app_id/app_name), " \
      "cancel (reap a stuck in-progress deployment so the app can deploy again — deployment_id, or app_id/app_name for its latest; marks it cancelled, doesn't touch the container), " \
      "convert_database (convert a shared-cluster app to a dedicated colocated DB IN PLACE so it can be transferred — app_id/app_name; requires confirm:true, a bare call previews. REVERSIBLE until redeploy: the shared DB is left intact and the old DSN kept as DATABASE_URL_PRE_CONVERT. credential_id/bucket optional — derived from the app's own R2 config), " \
      "transfer_plan (READ-ONLY dry-run of moving an app to another server — app_id/app_name + target_server_id/target_server_name; emits the staged change set + warnings, mutates nothing), " \
      "transfer (EXECUTE a move/clone to another server — app + target_server + mode + credential_id/bucket for the DB copy; requires confirm:true, a bare call returns the plan and does nothing). " \
      "deploy, rollback, and transfer are destructive/outward-facing — confirm with the user first.",
    input_schema: {
      type: "object",
      properties: {
        action:            { type: "string", enum: %w[create update deploy rollback sync_status cancel convert_database transfer_plan transfer], description: "Which app operation" },
        target_server_id:   { type: "integer", description: "transfer_plan/transfer: destination server by id (or target_server_name)" },
        target_server_name: { type: "string",  description: "transfer_plan/transfer: destination server by name (or target_server_id)" },
        mode:              { type: "string",  enum: %w[transfer clone stage], description: "transfer: 'transfer' (move + cut over + drain source), 'clone' (cut over, source stays live), or 'stage' (copy + deploy + publish, STOP before DNS so you can verify the target first). Default transfer." },
        confirm:           { type: "boolean", description: "transfer: required to execute. Without it, returns the dry-run plan and does NOTHING — a transfer redeploys, copies the DB, repoints DNS, and drains the source." },
        credential_id:     { type: "integer", description: "transfer (confirm): object-store (R2/S3) credential id used to copy the database" },
        bucket:            { type: "string",  description: "transfer (confirm): object-store bucket to stage the DB copy through" },
        provider:          { type: "string",  description: "transfer (confirm): object-store vendor for the DB copy (default cloudflare_r2; any S3-compatible BackupVendors key)" },
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
