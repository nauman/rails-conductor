class AddGithubAppGrantedAtToOrganizations < ActiveRecord::Migration[8.0]
  # The instance-wide GitHub App serves only organizations granted it (see
  # GithubApp.serves?). Every org that exists today was admitted by the operator
  # on an invite-only instance and already used the App, so all of them are
  # granted here: nothing changes for them. Only orgs created later, while sign-up
  # is open, start ungranted.
  def up
    add_column :organizations, :github_app_granted_at, :datetime
    execute "UPDATE organizations SET github_app_granted_at = CURRENT_TIMESTAMP"
  end

  def down
    remove_column :organizations, :github_app_granted_at
  end
end
