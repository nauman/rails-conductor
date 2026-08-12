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

  def check_item(item_id:, done:, expected_revision: nil)
    resolved = resolve
    result = Jazari.check_item(target: target, expected_revision: expected_revision || resolved.revision,
                               item_id: item_id.to_s, done: done)
    run = open_run
    run = Jazari.tick(run: run, expected_revision: run.lock_version,
                      item_id: item_id.to_s, done: done, actor_ref: @actor_ref)
    close_if_complete(run, resolve)
    result
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
