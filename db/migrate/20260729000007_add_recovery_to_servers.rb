# After a Conductor-initiated reboot, RebootRecoveryJob babysits the box back to
# health: it waits for SSH to return, then verifies + remediates each app. These
# columns store the outcome of that pass so the UI/MCP can show what recovery did
# (which apps were healthy, restarted, or still down) instead of leaving it opaque.
class AddRecoveryToServers < ActiveRecord::Migration[8.1]
  def change
    add_column :servers, :last_recovery_at, :datetime
    add_column :servers, :last_recovery_report, :text
  end
end
