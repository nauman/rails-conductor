# Consolidated database tool: flat `action` enum delegating via EnumDispatch.
class ConductorDatabaseTool
  include EnumDispatch

  ACTIONS = {
    "register_cluster" => RegisterDatabaseClusterTool,
    "provision"        => ProvisionDatabaseTool,
    "backup_now"       => RunBackupTool
  }.freeze

  DEFINITION = {
    name: "conductor_database",
    description: "Postgres databases. Set `action` to one of: " \
      "register_cluster (register a running postgres container apps can provision on — name, container_name, admin_username, admin_password; server via server_id/server_name; optional port), " \
      "provision (create a role+database+password on a cluster and return its URL — pass app_id and OMIT name to follow the convention <app>_production; cluster via cluster_id/cluster_name; optional username, and name only to create under a different name), " \
      "backup_now (run an app's DB backup right now and report the real result — app_id/app_name; proves the dump+upload actually works instead of trusting the nightly schedule).",
    input_schema: {
      type: "object",
      properties: {
        action:            { type: "string", enum: %w[register_cluster provision backup_now], description: "Which database operation" },
        app_name:          { type: "string",  description: "backup_now: target app by name (or app_id)" },
        name:              { type: "string",  description: "cluster name (register_cluster); for provision, OMIT it and pass app_id to follow the naming convention" },
        server_id:         { type: "integer", description: "register_cluster: host server by id (or server_name)" },
        server_name:       { type: "string",  description: "register_cluster: host server by name (or server_id)" },
        container_name:    { type: "string",  description: "register_cluster: postgres container name" },
        admin_username:    { type: "string",  description: "register_cluster: admin role" },
        admin_password:    { type: "string",  description: "register_cluster: admin role password" },
        port:              { type: "integer", description: "register_cluster: postgres port (default 5432)" },
        cluster_id:        { type: "integer", description: "provision: target cluster by id (or cluster_name)" },
        cluster_name:      { type: "string",  description: "provision: target cluster by name (or cluster_id)" },
        username:          { type: "string",  description: "provision: role name. With app_id and no name it follows the app convention (database <app>_production, role <app>); with an explicit name it defaults to that name" },
        app_id:            { type: "integer", description: "provision: app to link the database to" },
        organization_slug: { type: "string",  description: "org slug (defaults to actor's first org)" },
        organization_id:   { type: "integer", description: "org id (overrides slug)" }
      },
      required: %w[action]
    }
  }.freeze
end
