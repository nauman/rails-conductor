class AddNotesToApps < ActiveRecord::Migration[8.1]
  def change
    add_column :apps, :notes, :text
  end
end
