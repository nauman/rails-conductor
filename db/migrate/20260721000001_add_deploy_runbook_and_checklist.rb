class AddDeployRunbookAndChecklist < ActiveRecord::Migration[8.1]
  # Per-app deploy runbook (free-form markdown) + an ordered, checkable deploy
  # checklist. Each app deploys differently; an operator or MCP agent reads the
  # runbook + works the checklist before/while deploying that app.
  def change
    add_column :apps, :deploy_runbook, :text

    create_table :deploy_checklist_items do |t|
      t.references :app, null: false, foreign_key: true
      t.integer :position, null: false, default: 0
      t.string :content, null: false
      t.boolean :required, null: false, default: true
      t.boolean :done, null: false, default: false
      t.datetime :done_at
      t.timestamps
    end
    add_index :deploy_checklist_items, [ :app_id, :position ]
  end
end
