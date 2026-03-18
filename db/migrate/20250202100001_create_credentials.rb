class CreateCredentials < ActiveRecord::Migration[8.0]
  def change
    create_table :credentials do |t|
      t.string :name, null: false
      t.string :provider, null: false
      t.text :api_key
      t.text :api_secret
      t.boolean :active, default: true

      t.timestamps
    end

    add_index :credentials, :provider
    add_index :credentials, :active
  end
end
