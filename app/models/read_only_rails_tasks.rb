# Rails/rake tasks that only READ — safe to run against production without the
# :execute capability (SC-009 Decision B).
#
# `conductor_app action=runner` accepts either arbitrary Ruby or a bare task
# name. Arbitrary Ruby is unrestricted code and stays owner-only, always. But
# treating `db:migrate:status` as equally dangerous made the editor role weaker
# than it needed to be: an editor who can deploy cannot ask whether migrations
# are pending, which is exactly the question you want answered before deploying.
#
# ALLOWLIST, deliberately — not a denylist. A task absent from this list needs
# :execute, so the failure mode of forgetting to classify something is "an
# editor is refused", never "an editor ran a migration". Adding an entry is a
# security decision: it must produce no writes, no jobs, no network mutations,
# and no side effects on the running app.
module ReadOnlyRailsTasks
  TASKS = %w[
    about
    db:version
    db:migrate:status
    db:abort_if_pending_migrations
    notes
    routes
    stats
    zeitwerk:check
  ].freeze

  module_function

  # True only for an exact match. No prefixes: `db:migrate:status` being safe
  # says nothing about `db:migrate`, and a prefix rule would quietly admit it.
  def allow?(task)
    TASKS.include?(task.to_s.strip)
  end

  def to_sentence = TASKS.join(", ")
end
