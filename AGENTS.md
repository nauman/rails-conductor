# Agent Instructions

## Project Context

- Conductor is a Rails 8 app with Turbo, Importmaps, and Tailwind.
- The UI focuses on fleet monitoring (servers/VMs), Docker deploys, database backups to S3/R2, and Caddy routing. Active Storage introspection is deferred (see `docs/dev/FEATURES.md`).
- Documentation lives under `docs/` and should stay concise and actionable.

## Git Commits

- Do not include AI attributions or disclaimers in commit messages.
- Write commits as if authored by a developer.

## On Session Start

1. Read `docs/INDEX.md` for the doc map and maintenance rules.
2. Open `docs/infra/INDEX.md` for infrastructure references.
3. Open `docs/dev/INDEX.md` for development guides.
4. Skim the specific file you are updating to preserve tone and format.

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
