class AddNetworkAliasNetworkToDatabaseClusters < ActiveRecord::Migration[8.0]
  def change
    # WHICH network the alias was observed on. Without it the timestamp certified a
    # hostname globally: an alias attached on an unrelated network satisfied the
    # check, and connect_host then handed every app a name Docker cannot resolve
    # from the network those apps are actually on.
    add_column :database_clusters, :network_alias_network, :string
  end
end
