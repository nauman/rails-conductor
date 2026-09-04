# Gates the ADR 0011 switch to an assigned alias.
#
# `connect_host` may only return `cluster-<id>` once that alias actually exists on
# the container — otherwise the URL names something Docker DNS cannot resolve, and
# every app on a shared cluster breaks at its NEXT deploy. That would be a worse
# failure than the rename it prevents, and it would arrive all at once.
#
# So existing clusters keep their typed name until an operator attaches the alias
# deliberately (a live database container's network has to be reconnected, which is
# a real interruption). New Conductor-created clusters get it at creation.
class AddNetworkAliasAttachedAtToDatabaseClusters < ActiveRecord::Migration[8.0]
  def change
    add_column :database_clusters, :network_alias_attached_at, :datetime
  end
end
