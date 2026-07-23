class AddViaCdnToSiteChecks < ActiveRecord::Migration[8.0]
  def change
    # Whether this response was served through a CDN/proxy (Cloudflare) — detected
    # from the response headers (cf-ray / server: cloudflare). Lets the monitor panel
    # know a site is already behind Cloudflare instead of re-recommending it.
    add_column :site_checks, :via_cdn, :boolean, default: false, null: false
  end
end
