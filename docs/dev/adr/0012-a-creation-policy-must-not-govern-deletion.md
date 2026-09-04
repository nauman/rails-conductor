# 0012. A creation policy must not govern deletion

Date: 2026-09-05

## Status

**Accepted (2026-09-05).** Implemented in `PostgresClusterClient` and
`DatabasesController`. Raised by an adversarial audit of ADR 0011's naming work,
which found that the guard added to make provisioning safe had made deletion
unsafe.

## Context

ADR 0011 added a check to `PostgresClusterClient#validate_identifier!`: refuse a
name that is over 63 bytes, reserved, or already an administrative role. That check
is correct **for creating** a database, and it was applied to every path that
touched an identifier — including `drop_database`.

Three consequences, and each is worse than the last:

1. A database that already exists under a now-refused name became **undroppable
   through Conductor**. The rule was written about names we are choosing; it was
   enforced against names that were already chosen, possibly years earlier, and
   possibly by someone else.

2. `DatabasesController#destroy` caught the resulting error, flashed *"Dropped the
   record, but the cluster reported: …"*, and **destroyed the record anyway**. So
   the failure mode was not "you cannot delete this" but "Conductor forgot about a
   database that is still running" — still holding disk, still holding credentials,
   and now invisible to every report that reads from the `databases` table.

3. The next provision under that name fails against a database nothing knows about,
   for a reason that no longer exists anywhere in the system.

The tightening and the record-destruction were independent defects. The tightening
made the second one *reachable*, which is what turned a latent bug into a live one.

## Decision

**Split the check by what it protects, and let deletion pass everything except
injection.**

- **`validate_shape!`** — is this a legal SQL identifier at all? This is injection
  safety. It applies to every path, always, including deletion.
- **`validate_identifier!`** — should we *choose* this name? Length, postgres-owned
  names, the cluster's admin role, reserved words. This is policy, and it applies to
  creation only.

And: **a failed drop keeps the record.** `DatabasesController#destroy` now returns
without destroying when the cluster refuses, because the record is the only thing
tracking a database that still exists.

## Consequences

**Accepted:**
- A name Conductor would no longer create can still be dropped. That asymmetry is
  the point: policy governs what we bring into existence, never what we are allowed
  to clean up.
- An operator can be left with a `Database` row they cannot delete through the UI
  while the cluster keeps refusing. That is the correct end state — the row is
  accurate, and the problem is on the cluster.
- `rake database_naming:audit` reports stored identifiers the creation policy would
  now refuse, so the asymmetry is visible rather than discovered during an incident.

**Rejected:**
- *Keep one check and add exceptions for the drop path.* The same list read two ways
  is how this happened; the two questions need two names.
- *Let the drop proceed and destroy the record on failure.* This is what shipped,
  and it converts a refusal into silent data loss.
- *Skip validation entirely on delete.* Shape is injection safety, not policy, and
  the identifier is interpolated into SQL on that path too.

## The general rule

A guard added to make an operation safe must be scoped to that operation. Applied to
its inverse it does not become more conservative — it becomes an obstacle in front of
the cleanup path, which is exactly where a system is least able to tolerate one.

Related: ADR 0011 (the naming work that introduced the guard), ADR 0010 (derived
state declares its refresh — the record-versus-derivation principle this relies on),
`docs/architecture/database-conventions.md`.
