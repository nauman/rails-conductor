require "test_helper"
require Rails.root.join("db/migrate/20260812130000_freeze_legacy_deploy_checklist_writes")

class FreezeLegacyDeployChecklistWritesTest < ActiveSupport::TestCase
  setup do
    org = Organization.create!(name: "Legacy Freeze Co")
    @app = org.apps.create!(name: "app", slug: "app")
    @item = @app.deploy_checklist_items.create!(content: "historical", done: false)
    @migration = FreezeLegacyDeployChecklistWrites.new.tap { |migration| migration.verbose = false }
    @migration.up
  end

  teardown do
    @migration&.down
  end

  test "database rejects direct inserts" do
    assert_raises(ActiveRecord::StatementInvalid) do
      ApplicationRecord.transaction(requires_new: true) do
        ApplicationRecord.connection.execute(<<~SQL)
          INSERT INTO deploy_checklist_items (app_id, position, content, required, done, created_at, updated_at)
          VALUES (#{@app.id}, 2, 'bypass', TRUE, FALSE, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
        SQL
      end
    end
  end

  test "database rejects direct updates" do
    assert_raises(ActiveRecord::StatementInvalid) do
      ApplicationRecord.transaction(requires_new: true) do
        ApplicationRecord.connection.execute(
          "UPDATE deploy_checklist_items SET done = TRUE WHERE id = #{@item.id}"
        )
      end
    end
  end

  test "deletes remain available for app cleanup" do
    assert_nothing_raised do
      ApplicationRecord.connection.execute("DELETE FROM deploy_checklist_items WHERE id = #{@item.id}")
    end
  end
end
