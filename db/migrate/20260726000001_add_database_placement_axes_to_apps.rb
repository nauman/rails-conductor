# App-transfer spec 26, Slice 1: the two per-app DB axes.
#   database_mode      — isolation: shared cluster vs dedicated container
#   database_placement — locality: on the app's box vs a dedicated DB host
# Decision A defaults: dedicated + colocated (portable by default). Additive,
# non-null with safe defaults — nothing reads these yet, so it is a no-op for
# running apps until the provisioner lands.
class AddDatabasePlacementAxesToApps < ActiveRecord::Migration[8.1]
  def change
    add_column :apps, :database_mode, :string, null: false, default: "dedicated"
    add_column :apps, :database_placement, :string, null: false, default: "colocated"
  end
end
