class AddDeployMethodToApps < ActiveRecord::Migration[8.1]
  def change
    add_column :apps, :deploy_method, :string, default: "docker", null: false
  end
end
