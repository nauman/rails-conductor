class AddReleaseVersionToDeployments < ActiveRecord::Migration[8.1]
  def change
    # The release identifier a rollback targets. For Kamal this is the KAMAL_VERSION
    # (the deployed git sha, which Kamal tags its images with); for native it will
    # be the timestamped release id once release-dir support lands.
    add_column :deployments, :release_version, :string

    # deploy | rollback — labels rollback deployments so the history reads
    # "rolled back to <version>" rather than a normal deploy.
    add_column :deployments, :kind, :string, default: "deploy", null: false
  end
end
