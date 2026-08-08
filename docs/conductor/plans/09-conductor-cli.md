# 09 — `conductor` CLI: a first-class Go CLI over the one machine surface

Status: **Spec — v1, 2026-08-08. Not started.**

The house pattern (inventlist, kuickr, nodepad): a Rails app grows one machine
surface, and three clients read it — MCP for agents, a Go CLI for humans and CI,
REST for anything else. Conductor has the first client and neither of the others
done properly:

| What exists | What it is | Why it isn't the CLI |
|---|---|---|
| MCP endpoint (`/mcp`, 10 tools) | The agent surface, token-authed, audited | Agents only; no human ergonomics, no CI story |
| `bin/conductor` | ~200-line Ruby shim that pipes secrets into MCP tool calls | A secrecy workaround, not a surface: no discoverability, no output contract, no exit codes |
| `conductor-cli/` (Rust) | Day-one relic, untouched since the initial commit, off the house standard | Dead weight; its 3k committed build artifacts were untracked 2026-08-08 |

Canon this spec builds on (cite, don't restate):
`74-dev-docs/dev/cli/GO_CLI_ARCHITECTURE.md` (§ references below are to it) and
`CLI_API_CONTRACT.md`. Conductor is open-source for anyone's fleet — nothing in
the CLI may assume this operator's boxes; every endpoint/account value comes
from config.

## Decisions

1. **Go, house standard, full §12 checklist.** cobra + `PersistentPreRunE`,
   context-injected `appctx` (not globals — this CLI is non-trivial), envelope
   output with breadcrumbs, `--jq`, the §8 exit-code enum, ldflags version,
   GoReleaser, `SURFACE.txt` snapshot.
2. **Lives in-repo at `cli/`** with its own `go.mod` (module
   `github.com/nauman/rails-conductor/cli`). One repo, one release ritual, the
   contract and its consumer ship together (`CLI_API_CONTRACT.md` §5). The Rust
   `conductor-cli/` is **deleted** in the same commit that scaffolds `cli/`.
3. **Transport v1 = the existing MCP tools endpoint.** The CLI speaks JSON-RPC
   `tools/call` to `/mcp` with a bearer token — the same wire `bin/conductor`
   proved. No new Rails surface is required for v1; the MCP tool inputs/results
   ARE the contract, and the tool set is already flat-enum + audited. A typed Go
   SDK (`cli/internal/sdk`) wraps each tool action as a method
   (`sdk.Read.FleetStatus(ctx)`, `sdk.App.Deploy(ctx, opts)`); the andon-cord
   rule (§4) applies — commands never build raw tool-call JSON.
4. **Auth: PAT-style MCP token.** `conductor auth login` (paste token) → system
   keyring, plaintext file fallback; `CONDUCTOR_TOKEN` env override for
   agents/CI (§5). No OAuth in v1 — Conductor's MCP tokens are already
   per-actor and revocable in the UI (the connect panel generates the config).
5. **Profiles = Conductor installs.** `(name, api_url, token ref)` — an operator
   with a work fleet and a home fleet switches with `--profile`/`CONDUCTOR_PROFILE`
   (§6). Project-local `.conductor.yaml` may pin `profile` + default `app`.
6. **Secrets never touch argv or output** — inherit `bin/conductor`'s one good
   idea as a contract: secret values are read from **stdin only**
   (`conductor app env set NAME KEY --secret < value`), and the envelope
   renderer masks any field the server marks secret. `bin/conductor` is retired
   only when `API-COVERAGE.md` shows its two verbs (set-env, raw call) covered.

## Command surface (v1 target)

One noun per MCP tool family; every row lands in `API-COVERAGE.md` as
`tool.action → command → status`.

| MCP tool.action | CLI |
|---|---|
| read.fleet_status | `conductor fleet` |
| read.situation | `conductor situation` (the resume point; default command) |
| read.server / logs / deployment / transfer / cloudflare | `conductor server show/logs`, `conductor deploys show` |
| app.deploy / cancel / rollback / sync_status | `conductor app deploy/cancel/rollback/status` |
| app.create / update / retire / transfer(_plan) | `conductor app create/update/retire/transfer` |
| app.runner | `conductor app run -- <task>` |
| app_config.set_env / list / generate_env (spec 08 asks) | `conductor app env set/list/generate` |
| database.* | `conductor db backup/restore/verify/clusters` |
| domain.* | `conductor domain ...` |
| server.install_packages / register | `conductor server install/register` |
| cron.* | `conductor cron ...` |
| storage.* | `conductor storage ...` |
| github.* | `conductor github ...` |
| runbook.* | `conductor runbook show/check` |

Breadcrumbs mirror the MCP results' `hint`/verify pointers — e.g. `app deploy`
returns the poll command; `situation` returns one suggested command per
needs-attention row.

## Mutating-action guardrail

MCP tools gate destructive actions behind `confirm:true`; the CLI maps that to
an interactive TTY prompt, `--yes` for scripts, and **refuses** in non-TTY mode
without `--yes` (exit 2). Deploy preflight `blocked` results render the blockers
and exit 1 — `--force` passes `force:true` through.

## Phases

1. **Scaffold + read-only** — `cli/` skeleton per §1, auth, profiles, SDK core,
   `fleet` / `situation` / `server` / `deploys` / `app status`. Delete the Rust
   relic. `AGENTS.md`, `API-COVERAGE.md`, `skills/conductor-cli/SKILL.md`,
   `bin/ci` gate (§10) from day one — not retrofitted.
2. **App lifecycle** — deploy/cancel/rollback/env (stdin secrets), runner. At
   the end of this phase `bin/conductor` is deletable; delete it.
3. **Fleet ops** — db/backup/verify, domain, cron, storage, server provisioning,
   github, runbook.
4. **Release** — GoReleaser, brew tap, `/docs` guide page (`docs/guides/cli.md`),
   connect-panel snippet for the CLI alongside the three MCP clients.

Each phase ends green on `bin/ci` (Go) AND the Rails suite, with the coverage
ledger current — a command without its row is unfinished (§11).

## Open questions

- **OQ-1** `generate_env` (spec 08 / kuickr ask #3) doesn't exist server-side
  yet — build it before or during phase 2 so the CLI never grows a client-side
  secret generator.
- **OQ-2** Streaming deploy logs: MCP results are request/response; `app deploy
  --follow` needs either polling `read.deployment` (cheap, v1 answer) or an SSE
  endpoint (new Rails surface — defer).
- **OQ-3** Does the kuickr/inventlist e2e harness pattern run against a seeded
  local Conductor (`bin/rails server` + fixture fleet) or a throwaway container?
  Same-repo makes the local server the natural choice.
