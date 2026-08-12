class FreezeLegacyDeployChecklistWrites < ActiveRecord::Migration[8.1]
  # Jazari is the source of truth. Keep the legacy table for rollback and parity
  # inspection, but make direct inserts and updates fail at the database boundary.
  # Deletes remain allowed so an App can be removed through its existing cascade.
  def up
    execute <<~SQL
      CREATE OR REPLACE FUNCTION prevent_legacy_deploy_checklist_writes()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      BEGIN
        RAISE EXCEPTION 'deploy_checklist_items is read-only; use Jazari';
      END;
      $$;
    SQL

    execute <<~SQL
      CREATE TRIGGER prevent_legacy_deploy_checklist_writes
      BEFORE INSERT OR UPDATE ON deploy_checklist_items
      FOR EACH ROW EXECUTE FUNCTION prevent_legacy_deploy_checklist_writes();
    SQL
  end

  def down
    execute <<~SQL
      DROP TRIGGER IF EXISTS prevent_legacy_deploy_checklist_writes
      ON deploy_checklist_items;
    SQL

    execute <<~SQL
      DROP FUNCTION IF EXISTS prevent_legacy_deploy_checklist_writes();
    SQL
  end
end
