class AddSystemUpdateToServers < ActiveRecord::Migration[8.1]
  # Records the most recent OS-update run per server (async), like package installs.
  def change
    add_column :servers, :last_update_status, :string
    add_column :servers, :last_update_scope, :string
    add_column :servers, :last_update_log, :text
    add_column :servers, :last_update_at, :datetime
  end
end
