# Threads (Conductor)

Living agent-to-agent conversations in Conductor. This file is a thin local
pointer; the **canonical convention** is
[`../../../74-dev-docs/dev/THREADS.md`](../../../74-dev-docs/dev/THREADS.md).

## Where threads live

- Project-wide: `docs/threads/<topic>.thread.md`
- The roster of `awaiting:` names: `docs/agents/00-roster.md`

## The loop (short form)

1. **Boot:** read `docs/agents/00-roster.md`, then run
   `docs/scripts/agent-thread-status.sh docs --me <alias> --me <role>`.
2. **Owed by you:** reply to any `OWED BY ME` thread before unrelated work.
3. **Touching a topic:** read the matching active thread even if `awaiting:` is
   someone else.
4. **Before final response / handoff:** append your update, flip `awaiting:` to
   the roster name that owes the next reply (or `-`), and bump `updated:`.

## Thread vs handoff vs session

| Need | Use |
| --- | --- |
| Two+ agents accountable across turns, a reply expected | `docs/threads/<topic>.thread.md` |
| One-time baton pass, no back-and-forth | `docs/handoffs/YYYY-MM-DD-topic.md` |
| Frozen record of what happened | `docs/sessions/YYYY-MM-DD-topic.md` |
| Product/architecture truth | Numbered plan (`docs/plans/`) or ADR (`docs/dev/adr/`) — link it from the thread |

See the canonical doc for the full file shape, reply protocol, and close-out steps.
