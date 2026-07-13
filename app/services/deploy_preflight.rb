# Deploy preflight — the gate that turns the four deploy rituals into checks
# instead of habits. Runs before Conductor dispatches a deploy and reports:
#
#   migrations — is there a post-deploy migrate+abort_if_pending gate for this
#                deploy method? (kamal: yes/fail-loud; docker/native: not yet)
#   seeds      — has a seed run been recorded for this app? (the seed ledger)
#   audit      — the target server's last ServerAudit rollup (block on at_risk)
#   threads    — an explicit deploy_hold an agent sets while a thread is owed
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
    Result.new(checks: [migrations_check, seeds_check, audit_check, threads_check])
  end

  private

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
    elsif last.succeeded?
      ok(:seeds, "Seeds", "last seed run succeeded #{last.applied_at&.to_date || last.created_at.to_date}")
    else
      fail_row(:seeds, "Seeds",
               "the most recent seed run failed (#{last.applied_at&.to_date || last.created_at.to_date}) — resolve before deploying")
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
