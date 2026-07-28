# R2 audit fix (finding 1): bind an R2 bucket to the org that owns it, so a
# mutating op (set_cors / connect_domain) can never touch a bucket belonging to
# another org that happens to share the same Cloudflare account. A bucket on an
# account belongs to exactly one org (first-use claim).
class CreateStorageBuckets < ActiveRecord::Migration[8.1]
  def change
    create_table :storage_buckets do |t|
      t.references :organization, null: false, foreign_key: true
      t.references :app, foreign_key: true
      t.string :name, null: false
      t.string :cloudflare_account_id, null: false
      t.timestamps
    end
    add_index :storage_buckets, [ :cloudflare_account_id, :name ], unique: true
  end
end
