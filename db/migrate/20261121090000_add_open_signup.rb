# Open hosted sign-up (plan 02): trust levels, the card check, sign-up intents,
# abuse flags, the trust-change audit trail, and proof-of-control for servers.
#
# Every existing organization is `trusted`: each was created by an invited user or
# a platform admin, so the column default preserves today's behaviour exactly.
# Only the open sign-up path writes `new`.
class AddOpenSignup < ActiveRecord::Migration[8.1]
  def change
    change_table :organizations, bulk: true do |t|
      t.string :trust_level, null: false, default: "trusted"
      t.string :signup_source
      t.datetime :card_verified_at
      t.string :stripe_customer_id
      t.string :stripe_setup_intent_id
    end
    add_index :organizations, :trust_level

    add_column :users, :email_verified_at, :datetime

    create_table :signup_intents do |t|
      t.string :email, null: false # encrypted (SignupIntent encrypts :email)
      t.string :email_digest, null: false
      t.string :token_digest, null: false
      t.string :ip
      t.string :ip_prefix
      t.datetime :terms_accepted_at, null: false
      t.datetime :expires_at, null: false
      t.datetime :consumed_at
      t.timestamps
    end
    add_index :signup_intents, :token_digest, unique: true
    add_index :signup_intents, :email_digest
    add_index :signup_intents, [ :ip_prefix, :consumed_at ]

    create_table :abuse_flags do |t|
      t.references :organization, null: false, foreign_key: true
      t.string :kind, null: false
      t.text :detail
      t.timestamps
    end

    create_table :trust_events do |t|
      t.references :organization, null: false, foreign_key: true
      t.references :user, foreign_key: true # nil = the scheduled promotion job
      t.string :from_level, null: false
      t.string :to_level, null: false
      t.string :reason, null: false
      t.timestamps
    end

    change_table :servers, bulk: true do |t|
      t.string :ownership_nonce
      t.datetime :ownership_verified_at
    end

    # Server names were unique across the whole instance, so a tenant learned
    # another tenant's server names by collision (§ 6 item 2). Names are display
    # identities, never control-plane paths, so they scope to the org. Existing
    # names are already globally unique, so this index cannot fail on old data.
    add_index :servers, [ :organization_id, :name ], unique: true
  end
end
