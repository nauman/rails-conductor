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

    # Default to the FAST stored summary — the live SSH probes (health/audit/
    # storage/sudo) are several round-trips and can blow the gateway timeout on a
    # loaded box. Opt into them with probe:true when you need the deep panels.
    probe = input["probe"] == true
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
      # Stored rollups (instant) — the badge state the UI shows before any live
      # re-check. Pass probe:true to add the live health/audit/storage/sudo detail.
      audit:   { last_status: server.last_audit_status, last_at: ts(server.last_audit_at) },
      updates: { last_status: server.last_update_status, last_scope: server.last_update_scope, last_at: ts(server.last_update_at) },
      harden:  { last_status: server.last_harden_status, last_at: ts(server.last_harden_at) },
      # Post-reboot babysit-recovery outcome (RebootRecoveryJob): what it verified
      # + remediated once the box came back. nil until a reboot has been recovered.
      recovery: { last_at: ts(server.last_recovery_at), report: server.last_recovery_report.presence },
      # Scheduled jobs — scope=app|server is now a real distinction (CronJob#app_id),
      # not inferred from the command. App-scoped jobs carry the app + rails task.
      cron_jobs: (server.cron_jobs.includes(:app).map do |c|
        { id: c.id, name: c.name, scope: c.scope, app: c.app&.name, task: c.task,
          schedule: c.schedule, cron: c.cron_expression, enabled: c.enabled?,
          command: c.command.to_s[0, 100] }
      end rescue []),
      ssh: {
        user:       server.ssh_user_or_default,
        port:       server.ssh_port_or_default,
        key:        server.ssh_key&.name,
        configured: server.ssh_configured?
      },
      apps: server.apps.map { |a| { name: a.name, status: a.status, domain: a.domain } },
      _organization: server.organization
    }

    data[:live] = safe { live_detail(server, ssh) } if probe

    Result.ok(data)
  end

  private

  # All four live probes over ONE SSH session (one connect) instead of four —
  # keeps the deep-panel read under the gateway budget. Each block is graded from
  # its raw output; a bad chunk degrades to an {error:}, never a crash.
  def live_detail(server, ssh)
    outs = ssh.run_batch([
      ServerHealth::PROBE,
      ServerAudit::PROBE,
      ServerStorage::PROBE_LITE, # no `du` scan — keeps the batched read under budget
      "sudo -n #{ServerSudo::CHECK} >/dev/null 2>&1 && echo SUDO_READY || echo SUDO_NO"
    ])
    return { error: ssh.error.presence || "no response from server" } if outs.compact.empty?

    {
      health:         safe { graded(ServerHealth.new(server).grade_output(outs[0].to_s)) },
      audit:          safe { graded(ServerAudit.new(server).grade_output(outs[1].to_s)) },
      storage:        safe { storage_detail(ServerStorage.new(server).from_output(outs[2].to_s)) },
      privileged_ops: { ready: outs[3].to_s.include?("SUDO_READY") }
    }
  end

  def graded(r) = { status: r.status, checks: map_checks(r.checks) }

  def storage_detail(r)
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
