class AddCiBuildWorkflowToApps < ActiveRecord::Migration[8.1]
  # The workflow file that builds this app's image in CI, e.g. "build.yml".
  # Presence is the opt-in: nil means Conductor never dispatches CI for this app and
  # the deploy path behaves exactly as it did before. Opting an app in is an act,
  # like build_role on a server — nothing should start using someone's CI minutes
  # because a default said so.
  def change
    add_column :apps, :ci_build_workflow, :string
  end
end
