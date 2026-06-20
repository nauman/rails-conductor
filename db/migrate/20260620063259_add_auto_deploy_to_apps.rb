class AddAutoDeployToApps < ActiveRecord::Migration[8.1]
  def change
    add_column :apps, :auto_deploy, :boolean, default: false, null: false
    add_column :apps, :webhook_secret, :string
  end
end
