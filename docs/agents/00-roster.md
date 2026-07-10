# Conductor Agent Roster

This file is the local address book for `awaiting:` values in Conductor thread
files (`docs/threads/*.thread.md`). Use these exact names before assigning a
thread reply or handoff target. See `docs/dev/THREADS.md` for the convention.

| Name | Type | Use when |
| --- | --- | --- |
| `operator` | human | Nauman must decide, approve a deploy, or unblock (`localvault`, GitHub secrets, prod access) |
| `deploy` | role | The deployment agent owes the next push/deploy/verify or a deploy-config question (see `docs/agents/deploy.agent.md`) |
| `staff-engineer` | role | Implementation judgment or code review is needed (see `docs/agents/staff_engineer.md`) |
| `specification` | role | Cross-surface spec, roadmap, plan, or ADR alignment is needed |
| `review` | role | Fresh-context review is needed before merge or publish |
| `claude` | alias | Claude Code owes the next implementation or docs reply |
| `codex` | alias | Codex owes the next implementation or docs reply |

## Thread Duty

On boot:

1. Read this roster so you know which names may appear in `awaiting:`.
2. Run the thread-status report:
   ```bash
   docs/scripts/agent-thread-status.sh docs --me <alias> --me <role>
   ```
   (Falls back to `../74-dev-docs/scripts/agent-thread-status.sh docs ...` if the
   local copy is absent.)
3. Reply first to any `OWED BY ME` thread.
4. If the report shows `WAITING ON OTHERS`, report the exact owner/path instead
   of idling silently.

Before final response or handoff:

1. If you changed work another agent depends on, append to the relevant thread.
2. If a reply is now owed, set `awaiting:` to the roster name that owes it.
3. If no reply is owed, set `awaiting: -`.
4. Update `updated: YYYY-MM-DD`.
