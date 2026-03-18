class CreateSshKeys < ActiveRecord::Migration[8.0]
  def change
    create_table :ssh_keys do |t|
      t.string :name, null: false
      t.text :private_key, null: false
      t.text :public_key
      t.string :fingerprint
      t.string :key_type
      t.text :passphrase

      t.timestamps
    end

    add_index :ssh_keys, :name, unique: true
    add_index :ssh_keys, :fingerprint
  end
end
