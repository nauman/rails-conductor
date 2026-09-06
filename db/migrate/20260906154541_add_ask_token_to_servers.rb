class AddAskTokenToServers < ActiveRecord::Migration[8.0]
  def change
    # Identifies WHICH box is asking Caddy's on-demand TLS gate. Caddy sends only
    # the domain, so without this the gate cannot tell one server from another and
    # would answer for every zone on the fleet — an open relay for certificate
    # issuance, and a fast route to a rate-limit that takes every cert with it.
    add_column :servers, :ask_token, :string
    add_index :servers, :ask_token, unique: true
  end
end
