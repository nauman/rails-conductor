# Ralph Methods

Lightweight process for scoping and tracking small features.

## Template

1. **Result** — What success looks like.
2. **Approach** — High-level plan and tradeoffs.
3. **Limits** — What is explicitly out of scope.
4. **Plan** — Steps, in order, with checks.
5. **Handoff** — What to verify, what remains.

## Looping Development

Use `docs/dev/CONDUCTOR-DEV-LOOP-PROMPT.md` when work should continue through repeated agent iterations. Each loop must pick one roadmap slice, declare acceptance criteria, run `bin/ci` and `bash docs/scripts/ralph-doc-check.sh`, write a session note, and stop on the documented attempt cap or stuck condition. Do not run an unbounded "finish all of Conductor" loop.

## Example (VM Monitoring)

- Result: Show status for each VM with CPU/memory/disk/uptime.
- Approach: Poll agent endpoint; cache results; surface in dashboard cards.
- Limits: No alerting in this iteration.
- Plan: Add model, fetcher job, controller wiring, UI cards.
- Handoff: Verify polling schedule and dashboard refresh.
