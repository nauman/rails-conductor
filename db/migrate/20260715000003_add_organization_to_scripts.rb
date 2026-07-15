class AddOrganizationToScripts < ActiveRecord::Migration[8.1]
  # Scripts are arbitrary shell run on servers. Without an org they were global:
  # any org owner could edit a built-in that then executes on other tenants'
  # servers. Give user scripts an organization; built-ins keep a NULL org and
  # become platform-admin-only. Uniqueness is scoped so orgs don't collide.
  def change
    add_reference :scripts, :organization, null: true, foreign_key: true

    remove_index :scripts, name: "index_scripts_on_name"
    add_index :scripts, [ :name, :organization_id ], unique: true, name: "index_scripts_on_name_and_organization_id"
  end
end
