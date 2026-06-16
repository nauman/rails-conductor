class AddOrganizationToResources < ActiveRecord::Migration[8.1]
  def change
    %i[servers apps credentials backups ssh_keys].each do |table|
      add_reference table, :organization, foreign_key: true, index: true
    end
  end
end
