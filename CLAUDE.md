# Claude Code Instructions

## Project Context

- Conductor is a Rails 8 app with Turbo, Importmaps, and Tailwind.
- The UI focuses on fleet monitoring (servers/VMs), Docker deploys, database backups to S3/R2, and Caddy routing. Active Storage introspection is deferred (see `docs/dev/FEATURES.md`).
- Documentation lives under `docs/` and should stay concise and actionable.

## Operating on Fleet Servers

- **Use the `deploy` user for anything app-level** — `docker exec`, logs, dumps,
  editing app files.
- **Root is a REGISTRATION-ONLY credential.** It is permitted only while no deploy
  user with sudo exists yet — i.e. `register` and `harden`. After that,
  `/etc/sudoers.d/90-deploy` grants `deploy ALL=(ALL) NOPASSWD:ALL`, so there is no
  privileged op the deploy user cannot do, and no honest reason to ask for root.
  The older wording ("root for provisioning, OS updates, packages") required
  classifying the work, and anything can be argued into "provisioning" — which is
  exactly how a manual root errand got queued for a wrapper `deploy` could install
  itself. See `docs/learnings/root-is-a-registration-only-credential.md`.
- **Never hand a human a privileged command without first proving the automated
  identity failed.** Route escalation through `ServerSudo.ensure!`, which repairs
  as the SSH user before anyone is asked for a credential. An un-attempted
  automated path is a skipped step, not a fallback;
  `test/services/root_is_registration_only_test.rb` fails the build on regressions.
- Root-run commands create `root:root` files that the container and the `deploy`
  user can never write or `chown` back. The breakage surfaces at the *next*
  deploy or backup, far from the command that caused it. See
  `docs/learnings/operate-as-deploy-not-root.md`.
- If `deploy` cannot do an app-level task, fix the provisioning (docker group,
  ownership, a scoped sudo rule). Do not escalate to root to get unblocked.
- Prefer Conductor's own audited paths (`conductor_app action=runner`,
  `conductor_server action=install_packages`) over hand-run SSH: they target the
  live container by construction and are recorded.

## Browser Automation

- **Manual UI audits: `agent-browser` 0.26+**, which drives Chrome over direct CDP.
  No Playwright or Puppeteer dependency, and no `--native` flag — direct CDP is the
  default in 0.26. Verify with `agent-browser --version` and `agent-browser doctor`;
  read `agent-browser skills get core --full` before the first command in a session.
- **Automated coverage stays in the existing Capybara/Selenium system tests.** A UI
  audit is for looking; a regression belongs in `test/system`. Do not reach for a
  browser CLI to assert something a system test should own.
- **Playwright only** where a repo already owns Playwright coverage, or as a
  fallback. This repo owns none — do not introduce it.
- **Always `--session <name>`, and close it when done** (`agent-browser --session
  <name> close`). A session is a live Chrome context; an unclosed one outlives the
  task that created it, and this machine has accumulated sixteen. `close --all`
  exists but is unsafe on a shared machine — other agents' sessions are
  indistinguishable from stale ones, since nothing reports idle time.

## Git Commits

- Do not include AI attributions or disclaimers in commit messages.
- Write commits as if authored by a developer.

## On Session Start

1. Read `docs/INDEX.md` for the doc map and maintenance rules.
2. Read `docs/agents/00-roster.md` (the `awaiting:` address book), then run
   `docs/scripts/agent-thread-status.sh docs --me <alias> --me <role>`. Reply to
   any `OWED BY ME` thread before unrelated work; report the owner of any
   `WAITING ON OTHERS` thread instead of idling. See `docs/dev/THREADS.md`.
3. Open `docs/infra/INDEX.md` for infrastructure references.
4. Open `docs/dev/INDEX.md` for development guides.
5. Skim the specific file you are updating to preserve tone and format.

## Before Final Response or Handoff

If you changed work another agent depends on: append to the relevant
`docs/threads/<topic>.thread.md`, flip `awaiting:` to the roster name that owes
the next reply (or `-`), and bump `updated:`. Skipping this hides the real state
from the next agent's boot scan.

## Authoring Rules

- Keep instructions concise, executable, and project-specific.
- Prefer checklists and ordered steps for setup and troubleshooting.
- Note assumptions (OS, versions, prerequisites) before commands.
- Use fenced code blocks for commands; annotate commands that modify state.
- Never include secrets, tokens, or real credentials.
- When adding new docs, update `docs/INDEX.md` and the relevant section index with a one-line description.

## Scenario Workflow

When user describes a use case (natural language), create a scenario doc:

1. **Create scenario file** in `docs/scenarios/sc-XXX-<slug>.md`
2. **Extract actors** — identify who/what is involved (user types, systems, external services)
3. **Define goals** — what the user wants to achieve
4. **Write scenario flows** — step-by-step interactions with preconditions and acceptance criteria
5. **Note data model implications** — what models/fields are needed
6. **Capture open questions** — unknowns that need decisions
7. **Update `docs/scenarios/INDEX.md`** — add entry to the scenario table

### Scenario Doc Structure

```markdown
# SC-XXX: Title

## User Story (Raw)
> Paste the user's original description verbatim

## Actors
| Actor | Description |

## Goals
1. Goal one
2. Goal two

## Scenario Flow
### Scenario X.1: Sub-scenario name
**Preconditions:** ...
**Flow:** numbered steps
**Acceptance Criteria:** checkboxes

## Data Model Implications
## Technical Notes
## Open Questions
## Priority
```

## Maintenance Checklist (Always)

- Verify links between index files and docs are accurate after edits.
- Keep repeated snippets in one canonical place and reference them rather than duplicating.
- Call out required environment variables and failure modes.
- Leave clear TODOs with context when gaps remain.
