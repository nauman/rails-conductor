class CreateEnvVariables < ActiveRecord::Migration[8.1]
  def change
    create_table :env_variables do |t|
      t.references :app, null: false, foreign_key: true
      t.string :key, null: false
      t.text :value
      t.boolean :secret, default: false

      t.timestamps
    end

    add_index :env_variables, [:app_id, :key], unique: true
  end
end
