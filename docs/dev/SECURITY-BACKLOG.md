# Security Backlog

Known, unfixed security weaknesses with a deliberate holding position. Each entry
records the exposure, the interim mitigation, and what a real fix requires.

Add an entry here rather than leaving a bare `TODO` in code — a comment next to
the vulnerable line is invisible to everyone not already reading that file.

---

## SB-001 · DatabasePull: shell interpolation + unrestricted restore target

**Status:** FIXED 2026-08-01 · **Severity:** was critical · **Found:** 2026-07-31 (audit during SC-009)

### Exposure

`DatabasePullService` builds a remote shell command by interpolating user-supplied
values that are never validated as identifiers:

- `source_database_url_var` — validated only for *presence*
  (`app/models/database_pull.rb:12`), then interpolated into the remote command
  (`app/services/database_pull_service.rb:63`, `:70`). A crafted variable name can
  break out of the interpolation and run arbitrary commands on the target host.
- `restore_target` — passed to `dropdb` and then recreated
  (`app/services/database_pull_service.rb:73`). It can name *any* locally reachable
  PostgreSQL database, including Conductor's own.

Both values are accepted straight from request params
(`app/controllers/database_pulls_controller.rb:48`).

### Fixed (2026-08-01)

All six steps below are implemented:

1. `source_database_url_var` is validated against `/\A[A-Z][A-Z0-9_]*\z/`, and
   **re-validated in `DatabasePullService#remote_dump_command`** so a row written
   by raw SQL or a console cannot reach the remote shell.
2. `restore_target` must appear in `DATABASE_PULL_RESTORE_TARGETS`, an explicit
   deployment-configured allowlist.
3. `postgres`, `template0`, `template1` and **every database in Conductor's own
   configuration** (primary, queue, cache, cable) are subtracted from that list,
   so the control plane cannot be dropped by a pull.
4. The allowlist is re-checked in `restore_local` immediately before `dropdb`.
5. The UI field is a **select over the allowlist**, not free text.
6. Destructive local commands already used argument-array execution; the remote
   command still transmits a string (SSH always does), which is why strict
   identifier validation is the boundary there.

The owner-only quarantine has been removed — it was standing in for a fix, not
providing one. Pulls remain an operator action because they are destructive to
the target.

Regression coverage: `test/models/database_pull_safety_test.rb`, including two
cases that bypass validation with `update_column` and assert the execution-time
gates still refuse.

### What the fix required

1. Validate `source_database_url_var` against a strict environment-identifier
   regex (`/\A[A-Z][A-Z0-9_]*\z/`) and reject anything else.
2. Resolve `restore_target` from an allowlist of known local databases instead of
   accepting free text.
3. Explicitly refuse Conductor's own database and any system database
   (`postgres`, `template0`, `template1`).
4. Run the restore with a role that lacks `DROP DATABASE` on Conductor's own DB,
   so a bypass cannot destroy the control plane.
5. Prefer argument-array execution over string interpolation for the remote
   command, so quoting is not the security boundary.
6. Require explicit confirmation and record audit evidence for any overwrite.

### Related

- `docs/scenarios/sc-009-editor-role.md` — the role work that surfaced this.

---

## SB-002 · Last-owner invariant is callback-only

**Status:** open · **Severity:** medium · **Found:** 2026-07-31 (audit during SC-009)

### Exposure

`Membership` enforces "an organization always has an owner" with a validation
(`on: :update`) and a `before_destroy` callback (`app/models/membership.rb`).
That covers every ordinary model write — controllers, jobs, normal console use —
but callbacks are skippable by design:

- `update_column` / `update_columns` / `update_attribute` skip validations.
- `delete` and relation `delete_all` skip destroy callbacks.
- Raw SQL skips both.

Any of these can leave an organization with zero owners, which makes it
permanently unmanageable through the UI: member management requires
`:manage_members`, which requires an owner.

### Interim mitigation (in place)

Every application code path goes through validated writes, and the invariant
covers the two real ways it was reachable (demotion and moving an owner
membership to another org). The gap is deliberate console/raw-SQL use.

### What a real fix requires

A database-level constraint, since the guarantee cannot be expressed in Ruby:

1. A Postgres `AFTER INSERT OR UPDATE OR DELETE ... FOR EACH STATEMENT` trigger
   on `memberships` that raises when an organization is left with no
   `role = 1` row — deferred to end-of-transaction so multi-step ownership
   handovers still work.
2. Alternatively, a nightly reconciliation job that reports ownerless orgs, if a
   trigger is judged too heavy. Detection, not prevention.

Recovery today is manual: a platform admin can re-assign ownership from the
console.

### Related

- `docs/scenarios/sc-009-editor-role.md`
