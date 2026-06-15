class CreateOrganizationsAndMemberships < ActiveRecord::Migration[8.1]
  def change
    create_table :organizations do |t|
      t.string :name, null: false
      t.timestamps
    end

    create_table :memberships do |t|
      t.references :user, null: false, foreign_key: true
      t.references :organization, null: false, foreign_key: true
      t.integer :role, null: false, default: 0
      t.timestamps
    end

    add_index :memberships, [ :user_id, :organization_id ], unique: true
  end
end
