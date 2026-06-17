class CreateDeployKeys < ActiveRecord::Migration[8.1]
  def change
    create_table :deploy_keys do |t|
      t.references :app, null: false, foreign_key: true, index: { unique: true }
      t.text :public_key, null: false
      t.text :private_key, null: false
      t.string :fingerprint
      t.timestamps
    end
  end
end
