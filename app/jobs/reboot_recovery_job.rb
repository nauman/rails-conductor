# Babysits a server back to health after a Conductor-initiated reboot.
#
# A reboot is where hidden couplings bite (see the runtime-architecture doc):
# host PG rebinding, colocated containers racing docker, leftover *-web containers
# fighting for a port. Left alone, the box comes back but an app or two stays down
# until a human notices. This job closes that gap:
#
#   1. Poll SSH until the box answers again (bounded — it must return within the
#      reboot grace window, else we stop and leave normal offline detection to it).
#   2. Refresh metrics so the record flips "rebooting" → "online".
#   3. Verify every syncable app; restart the ones that should be running but
#      aren't (exited/dead container, failed status), then re-verify.
#   4. Record a legible report of what recovery did, per app.
#
# Enqueued (with a short initial delay) by RebootServerTool / ServersController#reboot.
class RebootRecoveryJob < ApplicationJob
  queue_as :ops

  POLL_INTERVAL  = 30.seconds
  MAX_ATTEMPTS   = 12 # ~6 min of polling — within Server::REBOOT_GRACE
  SETTLE_ATTEMPTS = 3 # if the box answers but hasn't actually rebooted yet, wait this long
  FRESH_BOOT     = 5.minutes # uptime under this = a genuine fresh boot

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

    remediate!(server, uptime)
  end

  private

  def repoll(server, attempt)
    self.class.set(wait: POLL_INTERVAL).perform_later(server.id, attempt + 1)
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
      ContainerStatus.new(app).sync!
      app.reload

      unless app.needs_attention?
        lines << "✓ #{app.name}: #{app.container_status}"
        next
      end

      # Should be running but isn't — restart, then re-verify.
      RestartAppJob.perform_now(app.id)
      safe_sync(app)
      app.reload

      if app.needs_attention?
        still_down += 1
        detail = app.status_check_error.presence || app.container_status
        lines << "✗ #{app.name}: restarted → still down (#{detail})"
      else
        restarted += 1
        lines << "↻ #{app.name}: restarted → #{app.container_status}"
      end
    end

    lines << "· #{native_skipped} native app(s) not container-synced (systemd-managed) — verify manually if down" if native_skipped.positive?

    uptime_note = uptime.positive? ? " (uptime #{(uptime / 60.0).round} min)" : ""
    header = "Reboot recovery on #{server.name}#{uptime_note}: " \
             "#{verified} app(s) verified, #{restarted} restarted, #{still_down} still down."
    server.record_recovery!([ header, *lines ].join("\n"))
  end

  def safe_sync(app)
    ContainerStatus.new(app).sync!
  rescue => e
    Rails.logger.warn "RebootRecoveryJob re-sync failed for #{app.name}: #{e.message}"
  end
end
