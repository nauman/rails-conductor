class AddKindToDatabaseClusters < ActiveRecord::Migration[8.0]
  def change
    # NULL means "not declared" — the inference stays in charge for clusters that
    # predate this column, so nothing is reclassified by the migration itself.
    add_column :database_clusters, :kind, :string
  end
end
