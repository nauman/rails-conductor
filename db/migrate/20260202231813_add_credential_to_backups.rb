class AddCredentialToBackups < ActiveRecord::Migration[8.1]
  def change
    add_reference :backups, :credential, foreign_key: true
  end
end
