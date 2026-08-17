# Fleet situation — the "pick up where you left off" snapshot for a reconnecting
# agent. MCP is stateless and agents disconnect; rather than session state, this
# assembles a lean orientation from the durable record so a fresh agent knows, in
# ONE read: what's running now, what needs a decision, and what just happened.
#
# Read-only. Org-scoped like fleet_status. Pairs with the idempotent, single-flight
# action layer (start_deployment! dedupes; blocked/forced attempts persist) so the
# agent can safely resume by re-issuing.
class FleetSituation
  # Two recoveries in the recent window is a pattern, not a coincidence.
  FLAPPING_RECOVERIES = 2

  # server_scope is an already-ACL'd relation (e.g. the actor's visible servers),
  # so the situation never leaks across tenants.
  def initialize(server_scope: Server.all, recent_limit: 8)
    @server_scope = server_scope
    @recent_limit = [ recent_limit.to_i, 25 ].min.clamp(1, 25)
  end

  def snapshot
    {
      in_flight:       in_flight,
      needs_attention: needs_attention,
      subjects:        subjects,
      recent:          recent,
      hint: "Resume by addressing needs_attention (each carries the app + next action), then read " \
            "`subjects` — each names the ritual its shape resolves to, its checklist progress and " \
            "whether the last run finished. `diverged: true` means an operator customised that " \
            "runbook and it no longer tracks the canon. " \
            "For an in-flight deployment, poll conductor_read action=deployment with its id. " \
            "Actions are single-flight/idempotent — re-issuing a deploy returns already_running, not a duplicate."
    }
  end

  private

  # Subject-scoped resume: for each app, the ritual its SHAPE resolves to, plus how
  # far through it we are and whether the last run finished.
  #
  # Composition, not duplication. FleetCanon names the shape and points at a recipe;
  # jazari owns the checklist, the run and the revision guard. Conductor holds neither
  # steps nor progress — it asks.
  #
  # Before this, `situation` said what was broken and nothing about what to DO: the
  # procedure lived in a session log, a learnings file, or one agent's memory, so it
  # could not be called by name.
  def subjects
    apps.includes(:server).map { |app| subject_row(app) }.compact
  end

  def subject_row(app)
    shape = FleetCanon.shape_for(app)
    resolved = Jazari.resolve(target: FleetCanon.target_for(app))

    {
      app: app.name,
      app_id: app.id,
      shape: shape,
      recipe_id: shape[:recipe_id],
      state: resolved.state,
      # `custom?` only says a row EXISTS. `origin` says WHY: a runbook the phase-2
      # backfill materialized is custom-but-INHERITED, and calling that diverged
      # would show six false divergences the day it lands — noise exactly when the
      # signal first appears. Comparing content against the canon cannot separate
      # them either, because a backfilled runbook genuinely differs (it carries the
      # app's hand-written steps). Provenance is the only honest discriminator.
      #
      # Falls back to `custom?` on jazari < 0.3, which has no origin, so this needs
      # no ordering against the gem bump in PR #36.
      diverged: resolved.respond_to?(:diverged?) ? resolved.diverged? : resolved.custom?,
      origin: (resolved.origin if resolved.respond_to?(:origin)),
      topic: resolved.topic,
      checklist: resolved.progress,
      last_run: AppRunbook.new(app).last_run_summary
    }
  rescue StandardError => e
    # One odd subject must not take down the resume point. Report the blindness.
    { app: app.name, app_id: app.id, recipe_id: nil,
      error: "could not resolve this subject's ritual: #{e.message}" }
  end

  def servers = @server_scope

  def apps
    App.where(server_id: servers.select(:id))
  end

  # What's happening right now.
  def in_flight
    ops = []
    Deployment.in_progress.where(app_id: apps.select(:id)).includes(:app).find_each do |d|
      ops << { type: "deployment", id: d.id, app: d.app&.name, status: d.status,
               started_at: d.started_at&.iso8601, forced: d.forced }
    end
    servers.find_each do |s|
      ops << { type: "server_update", server: s.name, scope: s.last_update_scope, status: "running" } if s.update_running?
      ops << { type: "package_install", server: s.name, status: "running" } if s.package_install_running?
    end
    ops
  end

  # What needs a human/agent decision — the resume worklist.
  def needs_attention
    items = []
    apps.includes(:server, :deployments, :seed_applications).find_each do |app|
      last = app.deployments.order(created_at: :desc).first
      if last&.status == "blocked"
        items << attn("blocked_deploy", app, deployment_id: last.id, blockers: last.preflight_blockers)
      elsif last&.status == "failed"
        # Carry the reason inline so the agent gets the actionable "why" (e.g.
        # "Missing required env var(s): …") without a second read to parse the log.
        items << attn("failed_deploy", app, deployment_id: last.id, reason: last.failure_reason)
      end

      seed = app.seed_applications.order(:created_at).last
      items << attn("failed_seed", app, when: seed.created_at.to_date.to_s) if seed&.status == "failed"

      items << attn("deploy_hold", app, reason: app.deploy_hold_reason) if app.deploy_hold?

      # Conductor's release record disagreeing with the box. Surfaced because a
      # stale record is trusted: an agent took a five-day-old FAILED deploy as
      # its release baseline and planned work against a machine that no longer
      # served traffic. Reads the stored rollup only — never probes here.
      if app.release_drift?
        items << attn("release_drift", app,
                      detail: app.release_state[:detail],
                      remedy: app.release_state[:remedy],
                      checked_at: app.release_checked_at&.iso8601,
                      stale: app.release_state_stale?)
      end

      # Residue from a previous form, read from the STORED rollup. The detector,
      # the hourly sweep and the columns all existed, but nothing surfaced them
      # here — so the resume point read "nothing wrong" while a stale route sat in
      # the rollup, and the residue on this fleet was found by hand instead.
      if app.residue?
        kinds = app.residue.map { |f| f[:kind] }.tally
                   .map { |kind, n| n > 1 ? "#{kind} ×#{n}" : kind }.join(", ")
        items << attn("residue", app,
                      count: app.residue.size,
                      detail: "#{kinds} — #{app.residue.first[:detail]}",
                      remedy: app.residue.first[:remedy],
                      stale: app.residue_stale?,
                      checked_at: app.residue_checked_at&.iso8601)
      end

      # A down public URL is an incident the operator sees in the UI — surface it here
      # too, with the status code / error so the agent knows what actually failed.
      check = app.latest_site_check
      if check&.status == :down
        detail = [ check.status_code && "HTTP #{check.status_code}", check.error.presence ].compact.join(" — ").presence || "unreachable"
        items << attn("site_down", app, detail: detail, checked_at: check.checked_at&.iso8601)
      elsif (recoveries = app.recent_retry_recoveries) >= FLAPPING_RECOVERIES
        # Serving, so never `site_down` — but a host that keeps failing its first
        # probe and passing the retry is unstable, and suppressing the blip must
        # not suppress that (codex review R-1).
        items << attn("site_flapping", app,
                      detail: "#{recoveries} of the last #{App::RETRY_RECOVERY_WINDOW} checks failed their first probe and passed the retry — serving, but unstable",
                      checked_at: check&.checked_at&.iso8601)
      end

      # DERIVED, not seeded. The obvious home for "adopt the CI build" is a checklist
      # item on the recipe — but RecipeRegistry.seed! is create-if-missing, so a new
      # item never reaches a runbook an operator has already customised, and this
      # fleet's busiest apps are exactly the customised ones. A rule that silently
      # skips the apps that need it most is worse than no rule. Computing it from
      # state reaches every app, every time, and disappears by itself once the app
      # stops building on a machine that serves.
      if app.build_host.present? && app.builds_on_a_serving_box? && app.ci_build_workflow.blank?
        items << attn("build_on_serving_host", app,
                      detail: "builds on #{app.build_host} — a machine that also serves traffic, so a deploy competes with what it is serving",
                      remedy: "add docs/templates/ci-build.yml to the repo and set ci_build_workflow, or point builder.remote at a box opted in with build_role")
      end
    end
    servers.find_each do |s|
      items << { kind: "at_risk_server", server: s.name, detail: "last audit graded at_risk — resolve before deploying" } if s.last_audit_status == "at_risk"
    end
    items.concat(backup_attention)
    items
  end

  # Backups were invisible here. Five failed in production while `situation`
  # reported nothing wrong — the control plane could not have told anyone that
  # backups had stopped being taken, which is the one failure you most want it to
  # notice. A backup nobody is taking is only discovered when it is needed.
  def backup_attention
    # Scoped through the SAME server relation as everything else here, so the
    # situation still cannot leak across tenants.
    Backup.enabled
          .where(server_id: servers.select(:id))
          .or(Backup.enabled.where(app_id: apps.select(:id)))
          .includes(:app).flat_map do |backup|
      label = backup.app&.name || backup.bucket_name

      case
      when backup.status == "failed"
        [ { kind: "failed_backup", app: label, backup_id: backup.id,
            detail: "last backup failed#{backup.last_run_at ? " at #{backup.last_run_at.iso8601}" : ''}" } ]
      when backup.stuck_running?
        [ { kind: "stuck_backup", app: label, backup_id: backup.id,
            detail: "stuck in 'running' since #{backup.last_run_at&.iso8601 || 'unknown'} — " \
                    "its process died; it is reaped and rescheduled automatically" } ]
      when backup.overdue?
        # Cite the field the condition is actually measured from. This used to
        # quote next_run_at — a FUTURE timestamp — as evidence that a backup was
        # overdue, which sent an operator hunting a stopped scheduler while the
        # scheduler was running normally.
        [ { kind: "overdue_backup", app: label, backup_id: backup.id,
            detail: "scheduled #{backup.schedule} but has not run since " \
                    "#{backup.last_run_at&.iso8601 || 'never'} — more than two intervals ago" } ]
      else
        []
      end
    end
  end

  # What just happened — terminal events, newest first.
  def recent
    Deployment.where(app_id: apps.select(:id))
              .where.not(status: %w[pending building deploying])
              .order(created_at: :desc).limit(@recent_limit).includes(:app)
              .map do |d|
      { id: d.id, app: d.app&.name, status: d.status, commit: d.commit_sha&.first(7),
        forced: d.forced, at: (d.completed_at || d.created_at)&.iso8601 }
    end
  end

  def attn(kind, app, **extra)
    { kind: kind, app: app.name, app_id: app.id,
      runbook: app.runbook_summary[:runbook].present?,
      checklist: app.runbook_summary[:checklist_progress] }.merge(extra)
  end
end
