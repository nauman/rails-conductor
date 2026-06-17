class AddOrganizationToApiTokens < ActiveRecord::Migration[8.1]
  def change
    add_reference :api_tokens, :organization, null: true, foreign_key: true
  end
end
