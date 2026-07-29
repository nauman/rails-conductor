# A Conductor-initiated reboot had no transitional state: the server stayed
# "online" until a metrics poll failed, then flipped to "offline" — firing a
# false server-down alert for an intentional reboot. rebooting_at marks the
# expected-down window so status shows "rebooting" instead, and no alert fires.
class AddRebootingAtToServers < ActiveRecord::Migration[8.1]
  def change
    add_column :servers, :rebooting_at, :datetime
  end
end
