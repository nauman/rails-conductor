class CreateSiteChecks < ActiveRecord::Migration[8.1]
  def change
    # One HTTP timing sample per app per run — the automated version of a curl -w
    # diagnosis. Powers the site latency/uptime monitor (sparkline + breakdown).
    create_table :site_checks do |t|
      t.references :app, null: false, foreign_key: true
      t.datetime :checked_at, null: false
      t.boolean  :up, null: false, default: false
      t.integer  :status_code
      t.integer  :dns_ms
      t.integer  :connect_ms   # TCP round-trip (≈ network distance)
      t.integer  :tls_ms
      t.integer  :ttfb_ms      # time to first byte (server + network)
      t.integer  :total_ms
      t.string   :error
      t.timestamps
    end
    add_index :site_checks, [ :app_id, :checked_at ]
  end
end
