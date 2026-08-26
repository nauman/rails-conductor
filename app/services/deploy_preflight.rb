# Deploy preflight — the gate that turns the four deploy rituals into checks
# instead of habits. Runs before Conductor dispatches a deploy and reports:
#
#   migrations — is there a post-deploy migrate+abort_if_pending gate for this
#                deploy method? (kamal: yes/fail-loud; docker/native: not yet)
#   seeds      — has a seed run been recorded for this app? (the seed ledger)
#   audit      — the target server's last ServerAudit rollup (block on at_risk)
#   threads    — an explicit deploy_hold an agent sets while a thread is owed
#   published_port — explicit host coordinate for Caddy container apps
#
# A :fail row blocks the deploy (callers pass force: to override); :warn is
# surfaced but does not block. Pure read — no SSH, no side effects.
class DeployPreflight
  Check  = Struct.new(:key, :label, :status, :detail, keyword_init: true)
  Result = Struct.new(:checks, keyword_init: true) do
    def blocked? = checks.any? { |c| c.status == :fail }

    def status
      return :blocked  if blocked?
      return :warnings if checks.any? { |c| c.status == :warn }
      :clear
    end

    def summary = checks.map { |c| "#{c.key}=#{c.status}" }.join(" ")
  end

  # Order fixed for a stable UI table: gates first, informational last.
  def initialize(app) = @app = app

  def check
    Result.new(checks: [ published_port_check, migrations_check, seeds_check, build_check, audit_check, threads_check, residue_check ])
  end

  private

  # Where the image gets built, BEFORE the click rather than in a log afterwards.
  # Conductor does not decide this: kamal reads `builder.remote` from the app's own
  # repo and the docker path builds over SSH on the target, so a UI user can start a
  # build on a production box without ever choosing to. Warn, never block — it is
  # often deliberate (avoiding arm64 emulation, say), and a gate on someone else's
  # config would be a gate nobody can satisfy from here.
  def build_check
    summary = @app.build_location_summary
    return skip(:build, "Build host", "native app — no image is built") if summary.nil?

    # Where the NEXT build would be placed, beside where the last one ran. The two
    # differ while an app's own repo still pins a builder, and seeing both is how an
    # operator learns that Conductor's choice is not yet the one taking effect.
    ladder = BuildPlacement.new(@app).ladder
    intended = ladder.find(&:available?) || ladder.last
    if intended.venue != :control
      return ok(:build, "Build host", "next build: #{intended} · last build: #{summary}")
    end
    # Never deployed is not a risk, it is an absence — the row still shows the
    # sentence, but warning on it would make "clear" unreachable for every new app
    # and train people to read past the warnings that mean something.
    return skip(:build, "Build host", summary) if @app.build_host.blank?
    # Falling through to control means every other rung was unavailable. Say WHY
    # each one was passed over: "it builds on a production box" is a complaint,
    # "CI has no workflow and no host is opted in as a builder" is a next step.
    return warn(:build, "Build host", "#{summary} · #{ladder_explanation(ladder)}") if @app.builds_on_a_serving_box?

    ok(:build, "Build host", summary)
  end

  # The rungs that were rejected, with the reason each one could not take the work.
  # Takes the ALREADY-COMPUTED ladder. Rebuilding it here re-ran the GitHub billing
  # probe — doubling the latency, and letting a transient answer contradict the
  # very placement being explained.
  def ladder_explanation(ladder)
    rejected = ladder.reject(&:available?)
    return "no cheaper build venue is available" if rejected.empty?

    "unavailable: " + rejected.map { |c| "#{c.venue} (#{c.reason.to_s.tr('_', ' ')})" }.join(", ")
  end

  def published_port_check
    caddy_container = @app.server&.edge_type == "caddy" && (@app.kamal? || @app.docker?)
    return skip(:published_port, "Host-published port", "not required for this deploy shape") unless caddy_container

    if @app.published_port.present?
      ok(:published_port, "Host-published port", "127.0.0.1:#{@app.published_port} recorded")
    else
      fail_row(:published_port, "Host-published port",
               "host-published port is not recorded — never substitute the container runtime port")
    end
  end

  # Reads the STORED rollup — no SSH, so this is safe on a page render and in a
  # deploy. WARNs rather than fails: residue is usually harmless right until a
  # deploy trips over it, and blocking every deploy on a leftover container
  # would be worse than the problem.
  def residue_check
    # An app that has never deployed cannot have left anything on a box, so
    # "not yet checked" is not worth a warning — it would fire on every new app.
    return ok(:residue, "Form residue", "nothing deployed yet") unless @app.ever_deployed?

    if @app.residue_checked_at.nil?
      return warn(:residue, "Form residue", "never checked — run a residue check to know")
    end

    findings = @app.residue
    # No view helpers in a service object; and a stale result must say so rather
    # than pass as current.
    label = @app.residue_stale? ? " (stale — last checked #{@app.residue_checked_at.to_fs(:short)})" : ""

    return ok(:residue, "Form residue", "no leftovers from a previous shape#{label}") if findings.empty?

    warn(:residue, "Form residue",
         findings.map { |f| "#{f[:kind]}: #{f[:detail]}" }.join(" · ") + label)
  end




  # NOTE: this is a *capability* check, not a live migration probe. It reports
  # whether the deploy method has a post-deploy migrate+abort_if_pending gate — it
  # does NOT inspect pending migrations or drift (the real migrate runs after the
  # release swaps; live pre-deploy drift detection is slot-24 remaining work).
  def migrations_check
    if @app.kamal?
      ok(:migrations, "Migration gate",
         "post-deploy gate present (db:migrate + abort_if_pending, fail-loud). Runs AFTER the release swaps — not a pre-deploy drift check.")
    else
      warn(:migrations, "Migration gate",
           "no post-deploy migration gate for #{@app.deploy_method} — migrations run unguarded; apply/verify by hand")
    end
  end

  # Evaluate the LATEST ledger entry: a recent failed seed run must block (a gate
  # that only looks at successes would wave through an app with a known failure).
  def seeds_check
    last = @app.seed_applications.order(:created_at).last
    if last.nil?
      warn(:seeds, "Seeds", "no seed run recorded for this app — run/record seeds if it needs them")
    elsif last.status == "failed" && @app.seed_on_next_deploy? && @app.kamal?
      # A seed retry is explicitly queued for THIS deploy — it will re-run the
      # failed seeds, so the failed record must not block the deploy that repairs
      # it (otherwise the only escape is Force, which bypasses every other gate).
      # Only Kamal actually runs seeds, so the downgrade is Kamal-only.
      warn(:seeds, "Seeds", "the most recent seed run failed — a retry is queued for this deploy")
    elsif last.status == "failed"
      fail_row(:seeds, "Seeds",
               "the most recent seed run failed (#{last.applied_at&.to_date || last.created_at.to_date}) — resolve it, or toggle 'seed on next deploy' to retry")
    elsif last.proven?
      ok(:seeds, "Seeds", "last seed run succeeded #{last.applied_at.to_date}")
    else
      # succeeded-without-evidence, or pending — never a free green.
      warn(:seeds, "Seeds", "latest seed record is unproven (#{last.status}, no applied_at) — re-run to confirm")
    end
  end

  # Only an explicit "secure" (and fresh) grade is OK. Anything unrecognized —
  # nil, a typo, a future status — must NOT fall through to secure (fail-open).
  def audit_check
    server = @app.server
    return skip(:audit, "Server audit", "no server attached") unless server

    case server.last_audit_status
    when nil, ""
      warn(:audit, "Server audit", "#{server.name} has never been audited — run an audit before shipping")
    when "at_risk"
      fail_row(:audit, "Server audit", "#{server.name} is at risk — resolve findings before deploying")
    when "attention"
      warn(:audit, "Server audit", "#{server.name} needs attention (see last audit)")
    when "secure"
      if server.audit_fresh?
        ok(:audit, "Server audit", "#{server.name} secure (audited #{server.last_audit_at.to_date})")
      else
        warn(:audit, "Server audit", "audit is stale (#{server.last_audit_at&.to_date || "never"}) — re-run to confirm posture")
      end
    else
      warn(:audit, "Server audit",
           "#{server.name} audit state '#{server.last_audit_status}' is unrecognized — re-run the audit (not assuming secure)")
    end
  end

  def threads_check
    if @app.deploy_hold?
      fail_row(:threads, "Threads / hold",
               @app.deploy_hold_reason.presence || "deploy is on hold (a coordination thread is owed)")
    else
      ok(:threads, "Threads / hold", "no deploy hold set")
    end
  end

  def ok(key, label, detail)   = Check.new(key: key, label: label, status: :ok,   detail: detail)
  def warn(key, label, detail) = Check.new(key: key, label: label, status: :warn, detail: detail)
  def skip(key, label, detail) = Check.new(key: key, label: label, status: :skip, detail: detail)
  def fail_row(key, label, detail) = Check.new(key: key, label: label, status: :fail, detail: detail)
end
