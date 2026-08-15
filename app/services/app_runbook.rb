# The Conductor adapter around Jazari's per-app runbook and run lifecycle.
#
# Controllers and MCP tools keep their existing surface, but all state now lives
# in Jazari. The legacy deploy_checklist_items table remains available only for
# the historical backfill and is never a write target here.
class AppRunbook
  def initialize(app, actor_ref: nil, actor: nil)
    @app = app
    @actor_ref = actor_ref || (actor && "user:#{actor.id}") || "system:conductor"
  end

  def target
    FleetCanon.target_for(@app)
  end

  def resolve
    Jazari.resolve(target: target)
  end

  def summary
    resolved = resolve
    {
      runbook: resolved.description,
      checklist: resolved.checklist.map { |item| item.merge(content: item[:text]) },
      checklist_progress: resolved.progress,
      revision: resolved.revision,
      state: resolved.state,
      origin: resolved.origin,
      last_run: last_run_summary
    }
  end

  def set_runbook(description:, expected_revision: nil)
    resolved = resolve
    Jazari.customize(target: target, expected_revision: expected_revision || resolved.revision,
                     topic: topic_for(resolved), description: description.to_s,
                     checklist: resolved.checklist)
  end

  def add_item(content:, required: true, expected_revision: nil)
    resolved = resolve
    Jazari.add_item(target: target, expected_revision: expected_revision || resolved.revision,
                    text: content, required: required)
  end

  def remove_item(item_id:, expected_revision: nil)
    resolved = resolve
    Jazari.remove_item(target: target, expected_revision: expected_revision || resolved.revision,
                       item_id: item_id.to_s)
  end

  # What a caller gets back: the tick landed, and whether the open run's evidence
  # could include it. `note` is present only when it could not, and says why.
  CheckResult = Struct.new(:resolved, :recorded_in_run, :note, keyword_init: true) do
    def recorded_in_run? = recorded_in_run
  end

  # Two writes that are NOT equals. The canonical tick is the checklist — it is the
  # answer to "is this step done". The run's tick is evidence, and evidence is
  # anchored to the checklist snapshot the run opened with. Treating a failure of
  # the second as a failure of the first is how a committed tick came back to its
  # caller as an error, whose natural response is to retry a half-applied write.
  #
  # A mid-run checklist edit is LEGAL, and since jazari 0.6.0 the RUN carries it:
  # `tick` widens the run's snapshot for an item added to the subject's own runbook
  # and marks both entries `post_snapshot: true`. So the ordinary case now records
  # cleanly and this rescue does not fire.
  #
  # It is narrowed rather than deleted, because one honest gap remains: the snapshot
  # widens from the SUBJECT's runbook only, never from the recipe — a recipe edited
  # mid-run is someone else's change arriving uninvited into an in-flight run, and
  # jazari refuses it by design. In that case phase 1 has still committed, and the
  # rule holds regardless of which gap caused it: never report failure for a write
  # that landed. Say what could not be recorded instead.
  #
  # The narrowing also fixes something the broad rescue got right only by luck.
  # `ItemNotInSnapshot` subclasses `ItemNotFound`, so catching the parent also
  # caught a genuinely unknown item — safe today only because phase 1 rejects those
  # first. Catching the precise class means a typo fails loudly by contract rather
  # than by call order.
  #
  # Every other phase-2 failure is a real failure, so both writes share a
  # transaction and it rolls back — a caller is never told a write failed while
  # that write stands committed.
  def check_item(item_id:, done:, expected_revision: nil)
    resolved = resolve
    recorded = true
    note = nil

    result = ActiveRecord::Base.transaction do
      outcome = Jazari.check_item(target: target, expected_revision: expected_revision || resolved.revision,
                                  item_id: item_id.to_s, done: done)
      run = open_run
      begin
        run = Jazari.tick(run: run, expected_revision: run.lock_version,
                          item_id: item_id.to_s, done: done, actor_ref: @actor_ref)
      rescue Jazari::ItemNotInSnapshot
        # Raised before any write, so nothing of phase 2 is pending here.
        recorded = false
        note = "step #{item_id} was ticked, but run #{run.id}'s snapshot cannot take it " \
               "(it comes from the recipe, not this subject's runbook), so that run's " \
               "evidence does not record it"
      end
      # Completion is a property of the CHECKLIST, not of the run's ticks, so a
      # step added mid-run still finishes the run when it is the last one.
      close_if_complete(run, resolve)
      outcome
    end

    CheckResult.new(resolved: result, recorded_in_run: recorded, note: note)
  end

  def attach_evidence(item_id:, kind:, value:)
    run = open_run
    Jazari.attach_evidence(run: run, expected_revision: run.lock_version,
                           item_id: item_id.to_s, kind: kind.to_s, value: value.to_s,
                           actor_ref: @actor_ref)
    last_run_summary
  end

  def reset(expected_revision: nil)
    resolved = resolve
    checklist = resolved.checklist.map { |item| item.merge(done: false) }
    result = if resolved.state == "default"
               resolved
             else
               Jazari.customize(target: target, expected_revision: expected_revision || resolved.revision,
                                topic: topic_for(resolved), description: resolved.description,
                                checklist: checklist)
             end
    close_open_run("abandoned")
    result
  end

  def last_run_summary
    run = runs.order(id: :desc).first
    return nil unless run

    {
      id: run.id,
      started_at: run.started_at,
      finished_at: run.finished_at,
      outcome: run.outcome,
      open: run.open?,
      actor_ref: run.actor_ref,
      evidence: run.evidence
    }
  end

  private

  def open_run
    existing = runs.where(finished_at: nil).order(id: :desc).first
    return existing if existing

    Jazari.open_run(target: target, actor_ref: @actor_ref).fetch(:run)
  end

  def close_if_complete(run, resolved)
    required = resolved.checklist.select { |item| item[:required] }
    return unless required.any? && required.all? { |item| item[:done] }

    Jazari.close_run(run: run, expected_revision: run.reload.lock_version, outcome: "completed")
  end

  def close_open_run(outcome)
    run = runs.where(finished_at: nil).order(id: :desc).first
    return unless run

    Jazari.close_run(run: run, expected_revision: run.lock_version, outcome: outcome)
  end

  def runs
    Jazari::Run.where(subject_type: @app.class.name, subject_id: @app.id)
  end

  def topic_for(resolved)
    resolved.topic.presence || "Conductor app runbook"
  end
end
