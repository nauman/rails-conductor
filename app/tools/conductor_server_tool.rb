# Consolidated server tool: flat `action` enum delegating via EnumDispatch.
class ConductorServerTool
  include EnumDispatch

  ACTIONS = {
    "register"        => RegisterServerTool,
    "update"          => UpdateServerTool,
    "add_ssh_key"     => GenerateSshKeyTool,
    "test_connection" => TestServerConnectionTool,
    "audit"           => ServerAuditTool,
    "apply_updates"   => ApplyServerUpdatesTool,
    "install_packages" => InstallServerPackagesTool,
    "run_script"      => RunScriptTool,
    "harden"          => HardenServerTool,
    "reboot"          => RebootServerTool,
    "remove"          => RemoveServerTool
  }.freeze

  DEFINITION = {
    name: "conductor_server",
    description: "Server management. IDENTITY RULE: Conductor operates every host as the " \
      "**deploy** user (the default when ssh_user is unset). Root is for provisioning and " \
      "hardening ONLY, and must be requested explicitly — never register or update a server " \
      "with ssh_user 'root' to get unblocked on an app-level task. Root-run commands leave " \
      "root:root files the container and the deploy user can never write or chown back, and " \
      "the breakage surfaces at the NEXT deploy, far from the command that caused it. If " \
      "deploy cannot do something, fix the provisioning (use action=harden, or the docker " \
      "group / ownership / a scoped sudo rule). Set `action` to one of: " \
      "register (add a host to the fleet — name, ip_address, ssh_user; optional ssh_key_id, provider), " \
      "update (change an existing host — server_id/server_name + any of name, ip_address, ssh_user, ssh_port, provider, region, and attach an SSH key via ssh_key_id or ssh_key_name), " \
      "add_ssh_key (generate a deploy keypair on the Conductor server — optional name; returns the PUBLIC key to add to your servers' authorized_keys, private key stays in Conductor), " \
      "test_connection (verify Conductor can SSH to a host and refresh its metrics — server_id/server_name; run this after attaching a key), " \
      "audit (read-only security/patch posture — server_id/server_name; firewall, SSH hardening, DB exposure, pending updates), " \
      "apply_updates (apply OS updates — server_id/server_name + scope security|all; with scope:all it REBOOTS when a kernel update leaves reboot-required, unless reboot:false — DISRUPTIVE, confirm first), " \
      "reboot (reboot a server now — server_id/server_name; via the vetted wrapper, scheduled so it returns cleanly. Use to activate a pending kernel. DISRUPTIVE — confirm), " \
      "install_packages (install OS packages — server_id/server_name + packages), " \
      "run_script (run a provisioning/deploy script on a server — server_id, script_name e.g. server-provision, ruby-install, app-setup), " \
      "harden (Hatchbox-style provision & harden — server_id/server_name; from root access Conductor creates a deploy+sudo user, enables ufw + fail2ban, disables SSH root/password login, closes an exposed host Postgres, and switches to managing the box as deploy. Never self-locks (root surrendered only after a live deploy+sudo check); idempotent. Turns an at-risk box green), " \
      "remove (deregister a server — server_id/server_name; refuses if apps are still attached unless force:true. Destructive — confirm).",
    input_schema: {
      type: "object",
      properties: {
        action:            { type: "string", enum: %w[register update add_ssh_key test_connection audit apply_updates install_packages run_script harden reboot remove], description: "Which server operation" },
        force:             { type: "boolean", description: "remove: deregister even if apps are still attached (detaches them)" },
        scope:             { type: "string", enum: %w[security all], description: "apply_updates: which updates (default security)" },
        reboot:            { type: "boolean", description: "apply_updates: reboot after applying when reboot-required (default true for scope:all, false for security)" },
        packages:          { type: "string", description: "install_packages: space/comma-separated package names" },
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
