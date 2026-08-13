class AddMetricsFailureCountToServers < ActiveRecord::Migration[8.0]
  def change
    add_column :servers, :metrics_failure_count, :integer, default: 0, null: false
  end
end
