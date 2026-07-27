# frozen_string_literal: true

# OAuth 2.1 authorization server tables (spec 06 — MCP OAuth connect).
#
# Beyond doorkeeper's generated schema this adds two columns Conductor needs on
# both grants and tokens, carried grant -> token by `custom_access_token_attributes`:
#   - resource        RFC 8707 audience indicator; /mcp refuses a token minted for
#                     another resource (confused-deputy / replay defence).
#   - organization_id the org the connector may act in. Conductor confines an MCP
#                     caller to one org (Current.org_scoped), exactly as an
#                     org-bound ApiToken does, so an OAuth token must carry one.
# PKCE columns are included here rather than in a follow-up: public clients
# (dynamic registration, no secret) authenticate with PKCE only.
class CreateDoorkeeperTables < ActiveRecord::Migration[8.1]
  def change
    create_table :oauth_applications do |t|
      t.string  :name,    null: false
      t.string  :uid,     null: false
      # Public (PKCE) clients register without a secret — doorkeeper still writes
      # a generated value, so this stays NOT NULL.
      t.string  :secret,  null: false
      t.text    :redirect_uri, null: false
      t.string  :scopes,       null: false, default: ""
      t.boolean :confidential, null: false, default: true
      t.timestamps             null: false
    end

    add_index :oauth_applications, :uid, unique: true

    create_table :oauth_access_grants do |t|
      t.references :resource_owner, null: false
      t.references :application,    null: false
      t.string   :token,            null: false
      t.integer  :expires_in,       null: false
      t.text     :redirect_uri,     null: false
      t.string   :scopes,           null: false, default: ""
      t.datetime :created_at,       null: false
      t.datetime :revoked_at

      # PKCE (RFC 7636) — required for the public clients DCR mints.
      t.string   :code_challenge
      t.string   :code_challenge_method

      # Conductor additions (see class comment).
      t.string   :resource
      t.references :organization
    end

    add_index :oauth_access_grants, :token, unique: true
    add_foreign_key :oauth_access_grants, :oauth_applications, column: :application_id
    add_foreign_key :oauth_access_grants, :organizations

    create_table :oauth_access_tokens do |t|
      t.references :resource_owner, index: true
      t.references :application,    null: false
      t.string   :token,            null: false
      t.string   :refresh_token
      t.integer  :expires_in
      t.string   :scopes
      t.datetime :created_at, null: false
      t.datetime :revoked_at
      # Present => doorkeeper revokes a refresh token only after the new access
      # token is used (RFC 6749 §6 rotation).
      t.string   :previous_refresh_token, null: false, default: ""

      # Conductor additions (see class comment).
      t.string   :resource
      t.references :organization
    end

    add_index :oauth_access_tokens, :token, unique: true
    add_index :oauth_access_tokens, :refresh_token, unique: true
    add_foreign_key :oauth_access_tokens, :oauth_applications, column: :application_id
    add_foreign_key :oauth_access_tokens, :organizations
  end
end
