class AddBuildHostToApps < ActiveRecord::Migration[8.1]
  # Where this app's image was ACTUALLY built, recorded by the deploy that built
  # it. Not a setting and not a policy — an observation, because Conductor does not
  # decide this: kamal reads `builder.remote` from the app's own repo, and the
  # docker path builds over SSH on the target by construction. Reporting a policy
  # instead of the fact told operators every app built on the control machine while
  # two kamal apps built on a box serving production traffic and every docker app
  # built on its own target.
  #
  # Nil means "no deploy has recorded it yet", which is a different statement from
  # any value and must stay distinguishable from one.
  def change
    add_column :apps, :build_host, :string
  end
end
