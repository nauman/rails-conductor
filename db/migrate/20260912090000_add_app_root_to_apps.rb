# A monorepo holds the Rails app in a subdirectory, so the deploy path needs two
# different roots: git still operates on the repository, while Kamal and every
# config read (config/deploy.yml, .kamal/secrets, config/master.key, db/seeds.rb)
# belong to the app inside it. Null/blank means the app IS the repository root,
# which is every existing app — hence no default and no backfill.
class AddAppRootToApps < ActiveRecord::Migration[8.0]
  def change
    add_column :apps, :app_root, :string
  end
end
