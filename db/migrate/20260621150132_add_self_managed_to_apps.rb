class AddSelfManagedToApps < ActiveRecord::Migration[8.1]
  def change
    # Marks the app that represents Conductor itself. A self-managed deploy
    # replaces the very container running the deploy job, so its success is
    # reconciled when the new release boots (see SelfDeployReconciler) rather
    # than observed inline.
    add_column :apps, :self_managed, :boolean, default: false, null: false
  end
end
