class AddSshFieldsToServers < ActiveRecord::Migration[8.0]
  def change
    add_reference :servers, :ssh_key, foreign_key: true
    add_column :servers, :ssh_user, :string, default: "root"
    add_column :servers, :ssh_port, :integer, default: 22
    add_column :servers, :metrics_updated_at, :datetime
  end
end
