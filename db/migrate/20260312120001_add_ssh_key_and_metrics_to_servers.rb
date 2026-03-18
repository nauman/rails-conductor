class AddSshKeyAndMetricsToServers < ActiveRecord::Migration[8.1]
  def change
    unless column_exists?(:servers, :ssh_key_id)
      add_reference :servers, :ssh_key, foreign_key: true
    end

    unless column_exists?(:servers, :metrics_updated_at)
      add_column :servers, :metrics_updated_at, :datetime
    end
  end
end
