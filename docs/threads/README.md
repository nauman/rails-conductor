# Threads

Living Conductor agent-to-agent conversations live here as `<topic>.thread.md`.

A thread is not a session log and not a handoff — it is an active conversation
with an explicit `awaiting:` owner-of-next-reply, kept append-only until resolved.

On boot, read `docs/agents/00-roster.md`, then run:

```bash
docs/scripts/agent-thread-status.sh docs --me <alias> --me <role>
# fallback if the local script is absent:
../74-dev-docs/scripts/agent-thread-status.sh docs --me <alias> --me <role>
```

`OWED BY ME` threads are replies you owe before unrelated work. `WAITING ON
OTHERS` means report the exact `awaiting:` owner and thread path instead of
sitting silently, unless the operator asked for a bounded wait loop.

Canonical convention: [`docs/dev/THREADS.md`](../dev/THREADS.md) (mirrors
`../74-dev-docs/dev/THREADS.md`).

## Active threads

| Thread | Participants | Awaiting |
| --- | --- | --- |
| [`self-describing-deploys`](self-describing-deploys.thread.md) | deploy ↔ staff-engineer | staff-engineer |
| [`stale-deploy-hold-reasons`](stale-deploy-hold-reasons.thread.md) | claude ↔ operator ↔ deploy | operator |
