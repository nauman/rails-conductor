# Babysits a server back to health after a Conductor-initiated reboot.
#
# A reboot is where hidden couplings bite (see the runtime-architecture doc):
# host PG rebinding, colocated containers racing docker, leftover *-web containers
# fighting for a port. Left alone, the box comes back but an app or two stays down
# until a human notices. This job closes that gap:
#
#   1. Poll SSH until the box answers again (bounded — it must return within the
#      reboot grace window, else we stop and leave normal offline detection to it).
#   2. Wait for Docker to actually be ready — SSH usually answers BEFORE the daemon
#      is up, and probing apps against a not-yet-ready daemon reads them all as down.
#   3. Refresh metrics so the record flips "rebooting" → "online".
#   4. Verify every syncable app; restart the ones that were meant to be running but
#      aren't (decided from the PRE-reboot desired state, not the post-sync one),
#      then re-verify.
#   5. Record a legible report of what recovery did, per app.
#
# Enqueued (with a short initial delay) by RebootServerTool / ServersController#reboot.
class RebootRecoveryJob < ApplicationJob
  queue_as :ops

  POLL_INTERVAL   = 30.seconds
  MAX_ATTEMPTS    = 12 # ~6 min of polling — within Server::REBOOT_GRACE
  SETTLE_ATTEMPTS = 3  # if the box answers but hasn't actually rebooted yet, wait this long
  FRESH_BOOT      = 5.minutes # uptime under this = a genuine fresh boot

  def perform(server_id, attempt = 1)
    server = Server.find_by(id: server_id)
    return unless server&.ssh_configured?

    unless SshConnection.new(server).test
      return repoll(server, attempt) if attempt < MAX_ATTEMPTS

      minutes = (MAX_ATTEMPTS * POLL_INTERVAL / 60).round
      server.record_recovery!("Reboot recovery: #{server.name} did not answer SSH within ~#{minutes} min. " \
                              "Left to normal offline detection — no remediation attempted.")
      return
    end

    # Reachable. Refresh metrics (flips rebooting → online, gives us uptime).
    ServerMetrics.new(server).fetch_and_update!
    server.reload
    uptime = server.uptime_seconds.to_i

    # Answered but clearly hasn't gone down yet (high uptime): keep waiting for the
    # real reboot, but don't loop forever — remediation is idempotent, so after a
    # few settle attempts we proceed anyway.
    if uptime.positive? && uptime >= FRESH_BOOT.to_i && attempt < SETTLE_ATTEMPTS
      return repoll(server, attempt)
    end

    # SSH usually comes back BEFORE Docker finishes starting. If we remediate now,
    # every container reads as down (sync returns unknown/exited), we fire useless
    # restarts against a dead daemon, and the pass ends prematurely. So wait for
    # Docker to be ready before touching containerized apps (bounded by MAX_ATTEMPTS).
    if runs_containers?(server) && !docker_ready?(server) && attempt < MAX_ATTEMPTS
      return repoll(server, attempt)
    end

    remediate!(server, uptime)
  end

  private

  def repoll(server, attempt)
    self.class.set(wait: POLL_INTERVAL).perform_later(server.id, attempt + 1)
  end

  def runs_containers?(server)
    server.apps.any?(&:can_sync_status?) # docker/kamal apps need the daemon
  end

  # Docker up + responsive. `docker info` exits non-zero until the daemon is ready.
  def docker_ready?(server)
    ssh = SshConnection.new(server)
    out = ssh.execute("docker info >/dev/null 2>&1 && echo READY || echo WAIT")
    ssh.success? && out.to_s.include?("READY")
  end

  def remediate!(server, uptime)
    lines = []
    verified = restarted = still_down = 0
    native_skipped = 0

    server.apps.includes(:server).order(:name).each do |app|
      unless app.can_sync_status?
        native_skipped += 1 if app.native? && app.naggable?
        next
      end

      verified += 1
      # Decide "should this be up?" from the PRE-sync record. ContainerStatus#sync!
      # rewrites a Kamal app whose container didn't return to status:"stopped" —
      # which needs_attention? then reads as a deliberate stop and would skip it.
      # Capturing intent first is what makes recovery actually restart lost apps.
      should_run = desired_up?(app)

      ContainerStatus.new(app).sync!
      app.reload

      if app.container_running?
        lines << "✓ #{app.name}: running"
        next
      end

      unless should_run
        lines << "· #{app.name}: #{app.container_status} (not expected up — left as is)"
        next
      end

      # Meant to be running but isn't — restart, then re-verify.
      RestartAppJob.perform_now(app.id)
      safe_sync(app)
      app.reload

      if app.container_running?
        restarted += 1
        lines << "↻ #{app.name}: restarted → running"
      else
        still_down += 1
        detail = app.status_check_error.presence || app.container_status
        lines << "✗ #{app.name}: restarted → still down (#{detail})"
      end
    end

    lines << "· #{native_skipped} native app(s) not container-synced (systemd-managed) — verify manually if down" if native_skipped.positive?

    uptime_note = uptime.positive? ? " (uptime #{(uptime / 60.0).round} min)" : ""
    header = "Reboot recovery on #{server.name}#{uptime_note}: " \
             "#{verified} app(s) verified, #{restarted} restarted, #{still_down} still down."
    server.record_recovery!([ header, *lines ].join("\n"))
  end

  # Was this app expected to be running before the reboot? Read from the STORED
  # record (last-known good) before sync mutates it — a managed app that was up.
  def desired_up?(app)
    app.naggable? && (app.status == "running" || app.container_running?)
  end

  def safe_sync(app)
    ContainerStatus.new(app).sync!
  rescue => e
    Rails.logger.warn "RebootRecoveryJob re-sync failed for #{app.name}: #{e.message}"
  end
end
