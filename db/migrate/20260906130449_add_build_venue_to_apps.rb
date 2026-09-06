class AddBuildVenueToApps < ActiveRecord::Migration[8.0]
  def change
    # Where this app's image is built, CHOSEN rather than inherited. Until now the
    # venue was an accident of configuration: DOCKER_HOST is set to the deploy target
    # only when that server has a stored SSH key, so an app built on the target or on
    # the control machine depending on something nobody was deciding.
    #
    # NULL means "not chosen" and keeps today's behaviour, so no existing app changes
    # venue on its next deploy. New apps get the default explicitly.
    add_column :apps, :build_venue, :string
  end
end
