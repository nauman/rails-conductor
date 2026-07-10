# Ralph Doc Loop

Minimal process for doc updates with tight context. For code-bearing development loops, use `docs/dev/CONDUCTOR-DEV-LOOP-PROMPT.md`.

## Startup

1. Read `docs/INDEX.md`, `docs/dev/INDEX.md`, and `docs/infra/INDEX.md`.
2. Read the target doc and any directly linked source doc.
3. Avoid loading broad code context unless the doc change depends on shipped behavior.

## Update Loop

1. Confirm the doc scope and acceptance criteria.
2. Draft changes; keep them concise and project-specific.
3. Update `docs/INDEX.md` and the relevant section index if a doc was added or renamed.
4. Run `bash docs/scripts/ralph-doc-check.sh`.
5. Summarize changes, verification, and open questions.

## Stop Conditions

- **Done:** requested doc change is complete and `bash docs/scripts/ralph-doc-check.sh` exits 0.
- **Attempt cap:** stop after 3 attempts on the same doc request.
- **Stuck:** stop if an iteration produces no meaningful diff or repeats the same unresolved question.
- **Manual:** stop immediately if the operator asks.
