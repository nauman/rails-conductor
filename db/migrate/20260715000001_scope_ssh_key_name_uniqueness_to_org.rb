class ScopeSshKeyNameUniquenessToOrg < ActiveRecord::Migration[8.1]
  # The model validates SSH-key name uniqueness per organization, but a global
  # unique index still raised RecordNotUnique when a second org used the default
  # "Conductor deploy key" name. Swap the global unique index for a scoped one.
  def change
    remove_index :ssh_keys, name: "index_ssh_keys_on_name"
    add_index :ssh_keys, [ :name, :organization_id ], unique: true, name: "index_ssh_keys_on_name_and_organization_id"
  end
end
