class ApplyUpdatesJob < ApplicationJob
  queue_as :ops

  def perform(server_id, scope, reboot = false)
    server = Server.find_by(id: server_id)
    return unless server

    result = SystemUpdater.new(server, scope: scope).apply

    # A kernel/libc upgrade leaves /var/run/reboot-required; without an actual
    # reboot the new kernel never runs and the audit stays at "reboot required".
    # When asked, reboot after a successful apply if the box now needs it.
    rebooted = false
    if result.success? && reboot && reboot_required?(server)
      rebooted = ServerReboot.new(server).reboot!.success?
    end

    server.update!(
      last_update_status: result.success? ? (rebooted ? "rebooting" : "succeeded") : "failed",
      last_update_scope:  scope,
      last_update_log:    (result.output.presence || result.error).to_s.last(20_000),
      last_update_at:     Time.current
    )
  end

  private

  def reboot_required?(server)
    res = SshConnection.new(server).execute_with_status("test -f /var/run/reboot-required && echo YES || echo NO")
    res[:output].to_s.include?("YES")
  end
end
