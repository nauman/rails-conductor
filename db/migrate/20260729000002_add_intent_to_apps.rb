# What the operator has DECIDED about an app, as distinct from what state it is in.
#
# Without this the fleet calls five apps "not deployed here" and every checklist and backup
# nag chases all of them — including two that are deliberately running until calm.page can
# serve them as themes, and two placeholders. See kuickr conductor/design/plan.html (R5).
class AddIntentToApps < ActiveRecord::Migration[8.1]
  def change
    add_column :apps, :intent, :string, null: false, default: "managed"
    add_column :apps, :intent_note, :string
    add_index :apps, :intent
  end
end
