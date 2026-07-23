class AddRegionEndpointToCredentials < ActiveRecord::Migration[8.1]
  def change
    # S3-compatible backup destinations differ only by endpoint + region + path-style.
    # account_id already exists (for R2). region (Wasabi/B2/Spaces) and endpoint
    # (MinIO/custom) complete the set.
    add_column :credentials, :region, :string
    add_column :credentials, :endpoint, :string
  end
end
