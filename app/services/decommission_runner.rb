# Drives a Decommission through the teardown pipeline, one phase at a time,
# recording the discovery report and every action on the record so a crash is
# visible and the run is auditable. Mirrors AppTransferRunner: each phase
# delegates the actual mutation to an injected deps object — the ENGINE (ordering,
# the retire-before-move safety, failure handling, the audit trail, folding
# learnings back into the runbook) is what this class owns and tests.
#
# The default Deps refuse to touch real infrastructure (NotWired), exactly like
# AppTransferRunner::Collaborators: the real teardown is FleetDeps, injected
# deliberately by whatever triggers a retire, so a run never fires blind.
class DecommissionRunner
  HANDLERS = {
    "containers"   => :remove_containers,
    "dedicated_db" => :remove_dedicated_db,
    "records"      => :clean_records
  }.freeze

  def initialize(decommission, deps: nil, plan: nil)
    @d = decommission
    @deps = deps || Deps.new(decommission)
    @plan = plan
  end

  # Runs the phases in order. Returns true on success; on any phase failure,
  # records the failing phase + message and stops. Records the discovery report
  # into #findings BEFORE executing, so the audit trail always answers "what did
  # we find before we touched anything?".
  def run
    # Safety, re-checked at execute time (not just when the plan was built): never
    # retire the app's live home — that orphans it. Must move home first.
    if @d.app.server_id == @d.server_id
      return fail_run!("refused: #{@d.app.slug} is still homed on #{@d.server.name} — move it (transfer) before retiring, or it is orphaned")
    end

    record_findings!
    @d.update!(status: "running", started_at: Time.current)

    Decommission::PHASES.each do |phase|
      @d.update!(phase: phase)
      @d.append_log("→ #{phase}")
      @deps.public_send(HANDLERS.fetch(phase))
      @d.append_log("✓ #{phase}")
    end

    append_learnings!
    @d.update!(status: "succeeded", finished_at: Time.current)
    true
  rescue StandardError => e
    # update_columns, not update!: recording a failure must never itself fail
    # validation (mirrors AppTransferRunner + append_log).
    @d.append_log("✗ #{@d.phase}: #{e.message}")
    @d.update_columns(status: "failed", finished_at: Time.current, updated_at: Time.current)
    false
  end

  private

  def plan
    @plan ||= DecommissionPlan.new(app: @d.app, server: @d.server).call
  end

  # Persist the discovery report to the audit trail before any mutation.
  def record_findings!
    @d.update_columns(findings: plan.to_h.to_json, updated_at: Time.current)
    plan.findings.each { |f| @d.append_log("• [#{f[:severity]}] #{f[:message]}") }
  rescue StandardError => e
    @d.append_log("• discovery unavailable: #{e.message}")
  end

  def fail_run!(message)
    @d.append_log("✗ #{message}")
    @d.update_columns(status: "failed", finished_at: Time.current, updated_at: Time.current)
    false
  end

  # Fold what discovery surfaced back into the app's runbook so the fleet stops
  # re-learning the same gotchas. Appends a concise, dated "decommission
  # learnings" note built from the gotchas that actually fired.
  def append_learnings!
    codes = @d.findings_data["findings"].to_a.map { |f| f["code"] }.uniq
    lines = codes.filter_map { |code| DecommissionGotchas.note(code) }
    return if lines.empty?

    note = +"## Decommission learnings (#{@d.server.name}, #{Date.current})\n"
    lines.each { |l| note << "- #{l}\n" }

    existing = AppRunbook.new(@d.app).resolve
    AppRunbook.new(@d.app, actor_ref: "system:decommission").set_runbook(
      description: [ existing.description.presence, note.strip ].compact.join("\n\n"),
      expected_revision: existing.revision
    )
  rescue StandardError => e
    @d.append_log("• runbook note skipped: #{e.message}")
  end

  # Mutating steps. Default is inert-and-loud (NotWired) so a decommission can't
  # run against real infrastructure without a deliberately injected deps object.
  class Deps
    class NotWired < StandardError; end

    def initialize(decommission)
      @d = decommission
    end

    def remove_containers   = not_wired!(:containers)
    def remove_dedicated_db = not_wired!(:dedicated_db)
    def clean_records       = not_wired!(:records)

    private

    def not_wired!(phase)
      raise NotWired, "#{phase} teardown is not wired to real infrastructure yet"
    end
  end
end
