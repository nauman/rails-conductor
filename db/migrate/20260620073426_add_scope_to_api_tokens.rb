class AddScopeToApiTokens < ActiveRecord::Migration[8.1]
  def change
    # "deploy" = full (mutating) access; "read" = read-only tools only.
    add_column :api_tokens, :scope, :string, default: "deploy", null: false
  end
end
