# Consolidated server tool: flat `action` enum delegating via EnumDispatch.
class ConductorServerTool
  include EnumDispatch

  ACTIONS = {
    "register"   => RegisterServerTool,
    "run_script" => RunScriptTool
  }.freeze

  DEFINITION = {
    name: "conductor_server",
    description: "Server management. Set `action` to one of: " \
      "register (add a host to the fleet — name, ip_address, ssh_user; optional ssh_key_id, provider), " \
      "run_script (run a provisioning/deploy script on a server — server_id, script_name e.g. server-provision, ruby-install, app-setup).",
    input_schema: {
      type: "object",
      properties: {
        action:            { type: "string", enum: %w[register run_script], description: "Which server operation" },
        name:              { type: "string",  description: "register: unique server name" },
        ip_address:        { type: "string",  description: "register: public IP or hostname" },
        ssh_user:          { type: "string",  description: "register: SSH login user" },
        ssh_key_id:        { type: "integer", description: "register: SshKey id for auth" },
        provider:          { type: "string",  description: "register: hetzner, digitalocean, linode, vultr, aws, gcp, azure" },
        organization_slug: { type: "string",  description: "register: org slug (defaults to actor's first org)" },
        organization_id:   { type: "integer", description: "register: org id (overrides slug)" },
        server_id:         { type: "integer", description: "run_script: server to run on" },
        script_name:       { type: "string",  description: "run_script: script name to run" }
      },
      required: %w[action]
    }
  }.freeze
end
