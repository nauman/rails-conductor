class AddEdgeToServers < ActiveRecord::Migration[8.1]
  # What routes traffic on this server's :80/:443 — a host Caddy, a kamal-proxy
  # container, something else, or nothing. Conductor had no concept of the edge
  # layer, so a kamal app configured for kamal-proxy could be deployed onto a
  # Caddy host with no warning (a trap this fleet hit in production).
  def change
    add_column :servers, :edge_type, :string
    add_column :servers, :edge_detail, :string
    add_column :servers, :edge_checked_at, :datetime
  end
end
