# `db:rollback` aborts on this app — and `db:migrate` then reports success

**Found:** 2026-09-08 · **Trigger:** a migration's backfill verified as "applied"
four times without ever having run · **Status:** rule for hand-run commands; no
code change

## The rule

```bash
bin/rails db:rollback:primary STEP=1   # works
bin/rails db:rollback STEP=1           # ABORTS — exits 1, changes nothing
```

Conductor is a multi-database app (`primary` + `queue`), and Rails refuses the
un-namespaced `db:rollback` for those. Use `db:rollback:primary`, and check the
exit status of a rollback rather than the output of the `db:migrate` that
follows it.

## Why it is worth a page

The failure is not that the command errors. It is that the pair of commands
*reads as success*.

The loop was: edit a migration, `bin/rails db:rollback STEP=1 && bin/rails
db:migrate`, then confirm the column exists. The rollback aborted, so the
version stayed in `schema_migrations`; `db:migrate` then had nothing to do and
exited 0 silently; and the column existed — from the *first* version of the
migration, applied before the edits. Every check passed. The backfill being
verified had never executed once.

Piping to `| tail -1` hid the abort message, and `&&` did not help because
`bin/rails` had already printed the failure to stdout before exiting.

What made it visible was checking the data instead of the schema: the backfill
was supposed to set rows to `false`, and no row was `false`.

## The general shape

A migration edited after it has been applied is not the migration that ran.
Nothing in `db:migrate:status` distinguishes them — it tracks versions, not
content. So when a migration body changes:

1. Roll back with the namespaced task and **read its output**, not just the
   exit code of the chain.
2. Verify the **effect** — query for the rows the migration was supposed to
   change — not the schema, which an earlier version may already have produced.
3. Remember that an installation which already ran the old body will never run
   the new one. Reconciling that needs a *new* migration, not an edit.

See also [`operate-as-deploy-not-root.md`](operate-as-deploy-not-root.md) for the
other flavour of this: a command whose damage surfaces far from where it ran.
