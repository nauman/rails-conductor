# Consolidated GitHub integration tool: flat `action` enum delegating via EnumDispatch.
class ConductorGithubTool
  include EnumDispatch

  ACTIONS = {
    "set_token"     => SetGithubTokenTool,
    "set_app"       => SetGithubAppTool,
    "installations" => GithubInstallationsTool
  }.freeze

  DEFINITION = {
    name: "conductor_github",
    description: "GitHub integration. Set `action` to one of: " \
      "set_token (store a per-org GitHub API token for auto deploy-key management — token; optional org), " \
      "set_app (configure Conductor's instance-wide GitHub App — app_id, private_key; admin only), " \
      "installations (list where the GitHub App is installed, or check a repo's reachability — optional repo; admin only).",
    input_schema: {
      type: "object",
      properties: {
        action:            { type: "string", enum: %w[set_token set_app installations], description: "Which GitHub operation" },
        token:             { type: "string",  description: "set_token: the GitHub API token" },
        organization_id:   { type: "integer", description: "set_token: org id (defaults to caller org)" },
        organization_slug: { type: "string",  description: "set_token: org slug" },
        app_id:            { type: "string",  description: "set_app: the GitHub App ID" },
        private_key:       { type: "string",  description: "set_app: App private key (PEM RSA)" },
        repo:              { type: "string",  description: "installations: optional 'owner/repo' to check reachability" }
      },
      required: %w[action]
    }
  }.freeze
end
