# Consolidated database tool: flat `action` enum delegating via EnumDispatch.
class ConductorDatabaseTool
  include EnumDispatch

  ACTIONS = {
    "register_cluster" => RegisterDatabaseClusterTool,
    "provision"        => ProvisionDatabaseTool
  }.freeze

  DEFINITION = {
    name: "conductor_database",
    description: "Postgres databases. Set `action` to one of: " \
      "register_cluster (register a running postgres container apps can provision on — name, container_name, admin_username, admin_password; server via server_id/server_name; optional port), " \
      "provision (create a role+database+password on a cluster and return its URL — name; cluster via cluster_id/cluster_name; optional username, app_id to link).",
    input_schema: {
      type: "object",
      properties: {
        action:            { type: "string", enum: %w[register_cluster provision], description: "Which database operation" },
        name:              { type: "string",  description: "cluster name (register_cluster) or database name (provision)" },
        server_id:         { type: "integer", description: "register_cluster: host server by id (or server_name)" },
        server_name:       { type: "string",  description: "register_cluster: host server by name (or server_id)" },
        container_name:    { type: "string",  description: "register_cluster: postgres container name" },
        admin_username:    { type: "string",  description: "register_cluster: admin role" },
        admin_password:    { type: "string",  description: "register_cluster: admin role password" },
        port:              { type: "integer", description: "register_cluster: postgres port (default 5432)" },
        cluster_id:        { type: "integer", description: "provision: target cluster by id (or cluster_name)" },
        cluster_name:      { type: "string",  description: "provision: target cluster by name (or cluster_id)" },
        username:          { type: "string",  description: "provision: role name (defaults to database name)" },
        app_id:            { type: "integer", description: "provision: app to link the database to" },
        organization_slug: { type: "string",  description: "org slug (defaults to actor's first org)" },
        organization_id:   { type: "integer", description: "org id (overrides slug)" }
      },
      required: %w[action]
    }
  }.freeze
end
