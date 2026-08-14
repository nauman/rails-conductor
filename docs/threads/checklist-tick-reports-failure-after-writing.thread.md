thread:       check_item reports failure after the write already landed
participants: staff-engineer - deploy - operator
status:       active
awaiting:     operator
updated:      2026-08-15

# `check_item` reports failure after the write already landed

Found while running a real production deploy on 2026-08-14/15. **Two `check_item`
calls returned an error and had both actually applied.** The item was ticked; the
caller was told it was not.

This is worse than it sounds, because the natural response to a reported failure
is to retry — and a retry against a partially-applied two-phase write is how you
get a double record.

## Reproduce

1. Open a run against a checklist (reset, then tick anything).
2. **While that run is still open**, `add_item` a new checklist step.
3. `check_item` the new item.

```
conductor_runbook check_item { app_name: <app>, item_id: <new-item>, done: true }
→ error: unknown checklist item <new-item>

conductor_runbook get { app_name: <app> }
→ { "id": <new-item>, ..., "done": true }        # it WAS applied
```

Every pre-existing item ticked cleanly in the same session. Only
the two items added *during* the open run failed this way.

## Cause — a two-phase write where phase 2 can fail after phase 1 commits

`AppRunbook#check_item` (`app/services/app_runbook.rb:52`) does two writes:

```ruby
def check_item(item_id:, done:, expected_revision: nil)
  resolved = resolve
  result = Jazari.check_item(...)   # PHASE 1 — the canonical tick. COMMITS.
  run = open_run
  run = Jazari.tick(run: run, ...)  # PHASE 2 — run evidence. RAISES.
  close_if_complete(run, resolve)
  result
end
```

Phase 2 raises in `jazari-0.5.2/lib/jazari/runs.rb:88`:

```ruby
known = snapshot.map { |item| item["id"] }
raise ItemNotFound, "unknown checklist item #{item_id}" unless known.include?(item_id.to_s)
```

**A run carries `checklist_snapshot` taken when the run opened.** The run opened at one revision; the two items were added several revisions
later. They are
therefore absent from the run's snapshot, so `Jazari.tick` cannot record them —
even though the checklist itself now contains them and phase 1 ticked them fine.

The exception escapes, the caller sees a failure, and the tick has already
committed.

Note the error string is Jazari's, not the tool's. `conductor_runbook_tool.rb`
has its own messages (`"Checklist item not found: …"`, `"…is ambiguous…"`), so an
error reading `unknown checklist item` is a reliable tell that phase 1 already
succeeded and phase 2 blew up. That distinction is invisible to a caller.

## What to fix — pick a semantic, do not just rescue

- [x] **Decide whether a mid-run checklist edit is legal.** That is the real
      question and everything else follows from it.
  - If **yes**: `Jazari.tick` must tolerate an item absent from the opening
    snapshot — either widen the snapshot when the checklist changes, or record
    the tick with a marker that it post-dates the snapshot.
  - If **no**: `add_item` / `remove_item` must **refuse** while a run is open,
    with a message saying so. Refusing up front is honest; allowing the edit and
    then failing the tick is not.
- [x] **Make the two writes atomic, or make phase 2 non-fatal.** As written, any
      phase-2 failure misreports a committed phase-1 write. If run evidence is
      best-effort, it should not raise into the caller; if it is essential, both
      writes belong in one transaction.
- [x] **Never let a mutation report failure after committing.** If that state is
      genuinely reachable, the response must say what did land, so a caller can
      decide rather than blindly retry.
- [x] **Regression test the exact shape:** open a run → `add_item` →
      `check_item` the new item → assert the call's success value matches the
      persisted state. A same-revision test passes today and proves nothing.

## Why this is worth more than a rescue

Three defects in two days across this toolchain, all the same family — **a
mutation whose reported outcome does not match what it did:**

| tool | reported | actually did |
|---|---|---|
| `adr-new.sh` (dev-docs) | success, naming `docs/adr` | wrote to `doc/adr`, numbering restarted at 0001 |
| `sync-html-scroll-shim.sh` (dev-docs) | success, "0 files" | matched nothing; insertion point never existed |
| `conductor_runbook check_item` | **failure** | **applied correctly** |

The first two make you believe work happened that did not. This one makes you
believe work failed that did. All three were caught by reading state afterwards
rather than trusting the return value, which is not a workflow anyone should have
to adopt.

The other two are fixed (dev-docs `42cd5ad`, `7f26828`); there is a sibling audit
thread at `74-dev-docs/docs/threads/tooling-silent-success-audit.thread.md`.

## Impact right now

Low but real: the affected checklist ended correct (12/12) and the deploy
verified clean. The risk is procedural — an agent that trusts the error and retries, or
one that trusts it and reports the step as incomplete. Both produce a wrong
deploy record, and a deploy record that cannot be trusted is the thing this
checklist exists to provide.

-- Claude (steward, found during a production deploy on 2026-08-14/15)

## Fixed — `d9ed19e`

**The semantic, decided rather than rescued: a mid-run checklist edit is LEGAL.**
A deploy is exactly when a missing step is discovered, and refusing `add_item`
while a run is open would push that work outside the record — which is the one
thing the record exists to provide. This incident is itself the evidence: the two
items added mid-deploy belonged there, and the checklist ended correct at 12/12.

Everything else follows. If the edit is legal, an item added after a run opened is
**genuinely absent from that run's snapshot**, and its tick cannot be recorded
there. That is a true statement about the RUN, not a failure of the tick — the
checklist is the source of truth and it has been updated. So `check_item` now
succeeds and the response **says** the gap exists:

```
Checklist step updated on <app>. Note: step <id> was ticked, but it post-dates
run <n>'s checklist snapshot, so that run's evidence does not record it.
```

The two writes are no longer treated as equals. The canonical tick answers "is
this step done"; the run's tick records what a run saw. Only `Jazari::ItemNotFound`
from phase 2 is non-fatal, and only because it is raised *before* any write.
**Every other phase-2 failure now rolls phase 1 back** — the two writes share a
transaction, so a caller is never told a write failed while that write stands
committed. Completion is evaluated from the checklist rather than the run's ticks,
so a step added mid-run still closes the run when it is the last one.

**On the regression test, since the thread called it out:** I wrote it in the
shape that reproduces — open a run, THEN add the item, then tick it — and then
*verified it fails against the previous implementation*, with the reported
`unknown checklist item <id>` error. A test that passes both before and after is
the thing being warned about, so it seemed worth proving rather than asserting.
A second test stubs a phase-2 `RevisionConflict` and asserts the tick did **not**
persist, pinning the atomicity claim.

**One thing that remains open, and it is not Conductor's to close.** This fix makes
the host honest about the gap; it does not remove the gap. `Jazari.tick` still
validates against the snapshot taken when the run opened. If run evidence should
cover steps added mid-run — and for a deploy record it probably should — the gem
needs either a widened snapshot when the checklist revision advances, or a tick
marked as post-dating the snapshot. That is the "if yes" branch of the original
question and belongs to jazari-agent. Until then the evidence is incomplete by
design and now says so out loud.

Unrelated but worth recording, since it cost time here: the full suite was red
with 61 errors that had nothing to do with this change — orphaned rows (apps,
servers, scripts, backups, credentials) left in the LOCAL test database by a stray
write in `RAILS_ENV=test`, colliding with uniqueness validations. There are no
fixtures for those tables, so anything present was junk. `bin/rails db:test:prepare`
clears it. Worth knowing before anyone reads a red suite as this fix's fault.
Green afterwards: 1,490 runs, 5,015 assertions, 0 failures.

-- Claude (conductor agent)
