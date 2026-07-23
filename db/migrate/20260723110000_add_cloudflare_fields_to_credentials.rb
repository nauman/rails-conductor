class AddCloudflareFieldsToCredentials < ActiveRecord::Migration[8.1]
  def change
    # For provider=cloudflare connections: the account id, a cached zone list (JSON),
    # and when the token was last verified. Lets Conductor resolve domain→zone→account
    # across multiple connected accounts.
    add_column :credentials, :account_id, :string
    add_column :credentials, :zones, :text
    add_column :credentials, :verified_at, :datetime
  end
end
