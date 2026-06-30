class AddPackageInstallToServers < ActiveRecord::Migration[8.1]
  # Records the most recent apt install run per server (installs are async, so we
  # need somewhere to land the result + drive the reactive panel).
  def change
    add_column :servers, :last_package_install_status, :string
    add_column :servers, :last_package_install_packages, :string
    add_column :servers, :last_package_install_log, :text
    add_column :servers, :last_package_install_at, :datetime
  end
end
