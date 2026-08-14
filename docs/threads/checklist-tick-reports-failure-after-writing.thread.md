thread:       check_item reports failure after the write already landed
participants: staff-engineer - deploy - operator
status:       active
awaiting:     staff-engineer
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

- [ ] **Decide whether a mid-run checklist edit is legal.** That is the real
      question and everything else follows from it.
  - If **yes**: `Jazari.tick` must tolerate an item absent from the opening
    snapshot — either widen the snapshot when the checklist changes, or record
    the tick with a marker that it post-dates the snapshot.
  - If **no**: `add_item` / `remove_item` must **refuse** while a run is open,
    with a message saying so. Refusing up front is honest; allowing the edit and
    then failing the tick is not.
- [ ] **Make the two writes atomic, or make phase 2 non-fatal.** As written, any
      phase-2 failure misreports a committed phase-1 write. If run evidence is
      best-effort, it should not raise into the caller; if it is essential, both
      writes belong in one transaction.
- [ ] **Never let a mutation report failure after committing.** If that state is
      genuinely reachable, the response must say what did land, so a caller can
      decide rather than blindly retry.
- [ ] **Regression test the exact shape:** open a run → `add_item` →
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
