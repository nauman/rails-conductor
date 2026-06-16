class AddOnboardedAtToOrganizations < ActiveRecord::Migration[8.1]
  def change
    add_column :organizations, :onboarded_at, :datetime
  end
end
