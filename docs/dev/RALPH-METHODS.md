# Ralph Methods

Lightweight process for scoping and tracking small features.

## Template

1. **Result** — What success looks like.
2. **Approach** — High-level plan and tradeoffs.
3. **Limits** — What is explicitly out of scope.
4. **Plan** — Steps, in order, with checks.
5. **Handoff** — What to verify, what remains.

## Example (VM Monitoring)

- Result: Show status for each VM with CPU/memory/disk/uptime.
- Approach: Poll agent endpoint; cache results; surface in dashboard cards.
- Limits: No alerting in this iteration.
- Plan: Add model, fetcher job, controller wiring, UI cards.
- Handoff: Verify polling schedule and dashboard refresh.
