# Full per-server detail for MCP — everything the /servers/N page shows, so an
# agent driving via MCP isn't half-blind to what an operator sees. Stored fields
# (metrics, update/harden status, cron, ssh, edge, apps) return instantly; the
# live SSH probes (health, audit, storage, privileged-ops readiness) each run
# defensively so a slow or failing probe degrades to an {error:} block instead of
# 504-ing the whole call. Pass probe:false to skip the live probes entirely.
class ServerDetailTool
  include ActorScoped

  def initialize(user:)
    @user = user
  end

  def call(input)
    server = find_server(input)
    return Result.fail("Server not found: #{input['server_id'] || input['server_name']}") unless server

    probe = input.key?("probe") ? (input["probe"] != false) : true
    ssh   = SshConnection.new(server)

    data = {
      id:       server.id,
      name:     server.name,
      ip:       server.ip_address,
      status:   server.status,
      provider: server.provider.presence,
      region:   server.region.presence,
      edge:     { type: server.edge_type, detail: server.edge_detail, detected: server.edge_detected? },
      metrics: {
        cpu:        server.cpu_percent,
        memory:     server.formatted_memory,
        disk:       server.disk_percent,
        load:       server.load_average&.to_f,
        uptime:     server.formatted_uptime,
        updated_at: ts(server.metrics_updated_at),
        last_seen:  ts(server.last_seen_at)
      },
      updates: { last_status: server.last_update_status, last_scope: server.last_update_scope, last_at: ts(server.last_update_at) },
      harden:  { last_status: server.last_harden_status, last_at: ts(server.last_harden_at) },
      cron_jobs: (server.cron_jobs rescue []),
      ssh: {
        user:       server.ssh_user_or_default,
        port:       server.ssh_port_or_default,
        key:        server.ssh_key&.name,
        configured: server.ssh_configured?
      },
      apps: server.apps.map { |a| { name: a.name, status: a.status, domain: a.domain } },
      _organization: server.organization
    }

    if probe
      data[:health]         = safe { health(server, ssh) }
      data[:audit]          = safe { audit(server, ssh) }
      data[:storage]        = safe { storage(server, ssh) }
      data[:privileged_ops] = safe { { ready: ServerSudo.ready?(ssh) } }
    end

    Result.ok(data)
  end

  private

  def health(server, ssh)
    r = ServerHealth.new(server, ssh: ssh).check
    r.ok? ? { status: r.status, checks: map_checks(r.checks) } : { error: r.error }
  end

  def audit(server, ssh)
    r = ServerAudit.new(server, ssh: ssh).audit
    r.ok? ? { status: r.status, checks: map_checks(r.checks) } : { error: r.error }
  end

  def storage(server, ssh)
    r = ServerStorage.new(server, ssh: ssh).load
    return { error: r.error } if r.error
    {
      mounts: r.mounts.map { |m| { filesystem: m.filesystem, size: m.size, used: m.used, avail: m.avail, percent: m.percent, mount: m.mount } },
      inodes: r.inodes.map { |m| { filesystem: m.filesystem, percent: m.percent, mount: m.mount } },
      swap:   r.swap,
      memory: r.memory
    }
  end

  def map_checks(checks)
    checks.map { |c| { key: c.key, label: c.label, status: c.status, detail: c.detail } }
  end

  def ts(time) = time&.strftime("%Y-%m-%d %H:%M UTC")

  # Never let one probe error take down the whole detail call.
  def safe
    yield
  rescue => e
    { error: "#{e.class}: #{e.message.to_s[0, 160]}" }
  end
end
