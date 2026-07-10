# Conductor Development Loop Prompt

Use this prompt to keep Conductor development moving in small, auditable loops. It is intentionally not a single unbounded "finish everything" instruction. Conductor is complete only when the roadmap, plans, tests, docs, and production checks agree.

## When to Use

- Use for one development loop against the next small roadmap slice.
- Use after reading `docs/INDEX.md`, `docs/dev/INDEX.md`, and `docs/infra/INDEX.md`.
- Use when the operator wants continued progress without reopening the whole product strategy.
- Do not use for destructive production actions, live deploys, provider billing changes, or credential work without explicit confirmation.

## Loop Contract

Every loop must declare these before work starts:

- **Success criteria:** the selected slice has passing tests, updated docs, and an auditable session note.
- **Attempt cap:** stop after 5 fix attempts for the same slice.
- **Stuck detector:** stop after 2 repeated failures with the same root cause, or after an iteration that produces no meaningful diff.
- **Manual override:** the operator can cancel the goal/loop at any time; for unattended runners use a stop file such as `/tmp/conductor-dev-loop.stop`.

## Source of Truth

Read in this order:

1. `docs/INDEX.md`
2. `docs/ARCHITECTURE.md`
3. `docs/dev/INDEX.md`
4. `docs/infra/INDEX.md`
5. `docs/dev/ROADMAP.md`
6. `docs/dev/FEATURES.md`
7. `docs/plans/INDEX.md`
8. `docs/analysis/pillars-audit-2026-03-19.md`
9. The specific plan, scenario, or code files touched by the selected slice

## Copy-Paste Goal

```text
/goal In /Users/your-user/Code/02-addons/79-conductor, complete one smallest valuable Conductor roadmap slice from docs/dev/ROADMAP.md and docs/plans/INDEX.md. Start by naming the selected slice and its acceptance criteria. Implement only that slice, add or update focused tests, update concise docs when product reality changes, and write a docs/sessions/YYYY-MM-DD-<topic>.md note with what changed, verification evidence, and remaining gaps. Stop only when bin/ci and bash docs/scripts/ralph-doc-check.sh pass, or after 5 fix attempts. If the same root cause fails twice, if no meaningful diff is produced, or if production/destructive credentials are needed, stop and report the blocker.
```

## Agent Prompt

```text
You are continuing Conductor development in /Users/your-user/Code/02-addons/79-conductor.

Goal: complete one smallest valuable slice toward the Conductor roadmap, with an audit trail.

Context rules:
- Read docs/INDEX.md, docs/ARCHITECTURE.md, docs/dev/INDEX.md, docs/infra/INDEX.md, docs/dev/ROADMAP.md, docs/dev/FEATURES.md, docs/plans/INDEX.md, and docs/analysis/pillars-audit-2026-03-19.md.
- Skim only the specific plan, scenario, and code files needed for the selected slice.
- Respect existing AGENTS.md instructions, Rails patterns, Turbo/Importmaps/Tailwind conventions, and org-scoped tenancy.

Pick the work:
1. Choose the next unchecked roadmap slice with the highest product unblock value.
2. State the selected slice, why it is next, the exact acceptance criteria, and the files likely to change.
3. If the slice is too large for one loop, split it and implement only the first independently useful sub-slice.

Build loop:
1. Check current git status and preserve unrelated user changes.
2. Add or update tests before or with implementation.
3. Keep changes scoped; do not refactor unrelated surfaces.
4. Update docs only when behavior, setup, roadmap status, or decisions changed.
5. Write a session note under docs/sessions/ with summary, files touched, verification evidence, and remaining gaps.

Verification:
- Run bin/ci.
- Run bash docs/scripts/ralph-doc-check.sh.
- For UI changes, run a browser smoke test and capture the relevant result.
- For infra/provider/deploy behavior, use mocks or dry-run checks unless the operator explicitly confirms live action.

Stop conditions:
- Success: selected acceptance criteria pass, bin/ci passes, docs check passes, and session note is written.
- Attempt cap: stop after 5 fix attempts on the same slice.
- Stuck: stop after 2 repeated failures with the same root cause or after an iteration with no meaningful diff.
- Manual: stop immediately if the operator asks, or if /tmp/conductor-dev-loop.stop exists in an unattended runner.

Final handoff:
- Report the slice completed or the exact blocker.
- Include verification commands and results.
- List changed files.
- List remaining gaps and the recommended next slice.
```

## Audit Checklist

Before calling a loop complete:

- [ ] Selected roadmap or plan slice is named.
- [ ] Acceptance criteria are explicit and narrow.
- [ ] Tests cover the behavior changed.
- [ ] `bin/ci` passed.
- [ ] `bash docs/scripts/ralph-doc-check.sh` passed.
- [ ] A session note records verification evidence.
- [ ] `docs/dev/ROADMAP.md`, `docs/dev/FEATURES.md`, or `docs/dev/CHANGELOG.md` changed if product reality changed.
- [ ] No secrets, tokens, real credentials, or destructive production actions were introduced.

## Reasonable Limits

This loop can steadily complete Conductor, but only by completing one verifiable slice at a time. If a task spans multiple pillars, split it into a plan or scenario first. If the loop uncovers missing product decisions, write the question into the relevant plan or session note and stop instead of guessing.
