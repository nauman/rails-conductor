# Harden runs as a background job (like apply_updates), so a synchronous MCP call
# never blocks past the gateway timeout. These columns track the last run so the
# tool can return immediately and the outcome stays inspectable.
class AddHardenStatusToServers < ActiveRecord::Migration[8.1]
  def change
    add_column :servers, :last_harden_status, :string
    add_column :servers, :last_harden_at, :datetime
    add_column :servers, :last_harden_log, :text
  end
end
