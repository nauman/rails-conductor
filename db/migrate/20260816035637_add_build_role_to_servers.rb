class AddBuildRoleToServers < ActiveRecord::Migration[8.1]
  # Marks a server as ELIGIBLE TO BUILD. Not where an app does build — that is
  # apps.build_host, an observation — but where Conductor may place a build when it
  # gets the choice. Intent and observation stay separate fields on purpose: this
  # week a recorded port that had drifted from reality made release identification
  # pick the wrong container, and collapsing "what we chose" into "what happened"
  # is how that starts.
  #
  # Default false, deliberately. Every box in this fleet serves something, so
  # opting a machine IN must be an act, never a default that quietly enlists a
  # production host.
  def change
    add_column :servers, :build_role, :boolean, default: false, null: false
  end
end
