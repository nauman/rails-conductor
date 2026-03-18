class AddDeploymentFieldsToApps < ActiveRecord::Migration[8.1]
  def change
    add_column :apps, :repository_url, :string
    add_column :apps, :branch, :string, default: "main"
    add_column :apps, :dockerfile_path, :string, default: "Dockerfile"
    add_column :apps, :image_name, :string
    add_column :apps, :health_check_path, :string, default: "/up"
    add_column :apps, :ssl_enabled, :boolean, default: true
    add_column :apps, :deployed_at, :datetime
  end
end
