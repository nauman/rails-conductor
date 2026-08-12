# Read-only parity audit for the migration window. Jazari is the source of truth;
# this service only compares the preserved legacy rows so retirement is evidence-led.
class LegacyRunbookAudit
  Result = Data.define(:apps, :issues, :legacy_items, :jazari_items) do
    def clean? = issues.empty?
  end

  def self.call
    new.call
  end

  def call
    rows = App.left_joins(:deploy_checklist_items)
              .where("deploy_checklist_items.id IS NOT NULL OR apps.deploy_runbook IS NOT NULL")
              .distinct
    issues = []
    legacy_items = 0
    jazari_items = 0

    rows.find_each do |app|
      legacy = app.deploy_checklist_items.order(:position, :id).to_a
      resolved = AppRunbook.new(app).resolve
      legacy_items += legacy.length
      jazari_items += resolved.checklist.length
      issues.concat(compare(app, legacy, resolved))
    end

    Result.new(apps: rows.count, issues: issues, legacy_items: legacy_items, jazari_items: jazari_items)
  end

  private

  def compare(app, legacy, resolved)
    issues = []
    issues << issue(app, "description") unless app.deploy_runbook.to_s == resolved.description.to_s

    expected = legacy.map do |item|
      { id: item.id.to_s, text: item.content.to_s, done: item.done == true,
        required: item.required != false }
    end
    actual = resolved.checklist.map { |item| item.slice(:id, :text, :done, :required) }
    issues << issue(app, "checklist") unless expected == actual
    issues
  end

  def issue(app, field)
    { app_id: app.id, app: app.name, field: field }
  end
end
