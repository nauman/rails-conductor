# Consolidated server tool: flat `action` enum delegating via EnumDispatch.
class ConductorServerTool
  include EnumDispatch

  ACTIONS = {
    "register"        => RegisterServerTool,
    "update"          => UpdateServerTool,
    "add_ssh_key"     => GenerateSshKeyTool,
    "test_connection" => TestServerConnectionTool,
    "run_script"      => RunScriptTool
  }.freeze

  DEFINITION = {
    name: "conductor_server",
    description: "Server management. Set `action` to one of: " \
      "register (add a host to the fleet — name, ip_address, ssh_user; optional ssh_key_id, provider), " \
      "update (change an existing host — server_id/server_name + any of name, ip_address, ssh_user, ssh_port, provider, region, and attach an SSH key via ssh_key_id or ssh_key_name), " \
      "add_ssh_key (generate a deploy keypair on the Conductor server — optional name; returns the PUBLIC key to add to your servers' authorized_keys, private key stays in Conductor), " \
      "test_connection (verify Conductor can SSH to a host and refresh its metrics — server_id/server_name; run this after attaching a key), " \
      "run_script (run a provisioning/deploy script on a server — server_id, script_name e.g. server-provision, ruby-install, app-setup).",
    input_schema: {
      type: "object",
      properties: {
        action:            { type: "string", enum: %w[register update add_ssh_key test_connection run_script], description: "Which server operation" },
        name:              { type: "string",  description: "register: unique server name; update: rename; add_ssh_key: key name" },
        ip_address:        { type: "string",  description: "register/update: public IP or hostname" },
        ssh_user:          { type: "string",  description: "register/update: SSH login user (e.g. root, deploy)" },
        ssh_port:          { type: "integer", description: "update: SSH port (default 22)" },
        ssh_key_id:        { type: "integer", description: "register/update: SshKey id to attach for auth" },
        ssh_key_name:      { type: "string",  description: "update: attach an SshKey by name (alternative to ssh_key_id)" },
        provider:          { type: "string",  description: "register/update: hetzner, digitalocean, linode, vultr, aws, gcp, azure" },
        region:            { type: "string",  description: "update: region label" },
        server_id:         { type: "integer", description: "update/test_connection/run_script: target server id" },
        server_name:       { type: "string",  description: "update/test_connection: target server by name" },
        organization_slug: { type: "string",  description: "register: org slug (defaults to actor's first org)" },
        organization_id:   { type: "integer", description: "register: org id (overrides slug)" },
        script_name:       { type: "string",  description: "run_script: script name to run" }
      },
      required: %w[action]
    }
  }.freeze
end
