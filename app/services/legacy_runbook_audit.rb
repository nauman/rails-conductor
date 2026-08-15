# Read-only accountability audit for the migration window. Jazari is the source of
# truth; this compares the preserved legacy rows so retirement is evidence-led.
#
# NOT a parity check, deliberately. The legacy table has no concept of a run and
# Jazari does: `done` on a runbook is CURRENT STATE, a tick on a run is WHAT THAT
# RUN SAW. A tick that was true inside a run that ended looks like permanent drift
# to a per-item comparison, and ticking it "closed" would assert verification that
# never happened in the current run. So a difference is allowed to exist provided it
# is WRITTEN DOWN with a reason: green means nothing UNEXPLAINED, not nothing
# differs. Unexplained differences still fail, which is the part that has teeth.
class LegacyRunbookAudit
  EXCEPTIONS_PATH = Rails.root.join("config", "legacy_runbook_exceptions.yml")

  Result = Data.define(:apps, :issues, :explained, :legacy_items, :jazari_items) do
    # Green when nothing is unexplained. `explained` is carried, not discarded —
    # an exception nobody can see is indistinguishable from a check that passed.
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
    explained = []
    legacy_items = 0
    jazari_items = 0

    rows.find_each do |app|
      legacy = app.deploy_checklist_items.order(:position, :id).to_a
      resolved = AppRunbook.new(app).resolve
      legacy_items += legacy.length
      jazari_items += resolved.checklist.length
      found, accounted = compare(app, legacy, resolved).partition { |i| exception_for(i).nil? }
      issues.concat(found)
      explained.concat(accounted.map { |i| i.merge(reason: exception_for(i)["reason"].to_s.strip) })
    end

    Result.new(apps: rows.count, issues: issues, explained: explained,
               legacy_items: legacy_items, jazari_items: jazari_items)
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

  def exception_for(issue)
    exceptions.find { |e| e["app_id"] == issue[:app_id] && e["field"].to_s == issue[:field].to_s }
  end

  # Missing file means no exceptions, not a crash: a fresh clone has nothing to
  # explain, and a check that cannot run is worse than one with nothing to say.
  def exceptions
    # safe_load, with Date permitted because the entries are dated — an exception
    # without a date is one nobody can tell has outlived its reason.
    @exceptions ||= if File.exist?(EXCEPTIONS_PATH)
      YAML.safe_load_file(EXCEPTIONS_PATH, permitted_classes: [ Date ]) || []
    else
      []
    end
  end
end
