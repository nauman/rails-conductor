# Security Backlog

Known, unfixed security weaknesses with a deliberate holding position. Each entry
records the exposure, the interim mitigation, and what a real fix requires.

Add an entry here rather than leaving a bare `TODO` in code — a comment next to
the vulnerable line is invisible to everyone not already reading that file.

---

## SB-001 · DatabasePull: shell interpolation + unrestricted restore target

**Status:** open · **Severity:** critical · **Found:** 2026-07-31 (audit during SC-009)

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

### Interim mitigation (in place)

Database pulls are **owner-only** (`owner_only :execute, :new, :create` in
`DatabasePullsController`). This does not fix the bug — any org owner can still
reach it — but it keeps the vulnerable path off the editor role introduced in
SC-009, rather than widening who can reach it.

### What a real fix requires

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
