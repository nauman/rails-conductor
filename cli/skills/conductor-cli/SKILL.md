---
name: conductor-cli
description: Operate a Conductor fleet from the terminal or a script — fleet health, the resume point, per-server detail, and token management. Use when a shell, CI step or cron job needs Conductor, when an exit code must be branched on, or when a token must not pass through a transcript. For interactive agent work the Conductor MCP tools are the better surface.
---

# conductor CLI

A Go CLI over Conductor's MCP endpoint. Same backend contract as the MCP tools,
different client.

## When to reach for this instead of the MCP tools

- **A script or CI step needs an answer.** MCP returns JSON to a model; there is
  no process to branch on. `conductor fleet || exit 1` works anywhere.
- **A secret must not enter a transcript.** An MCP tool call carries its
  arguments through the model's context. `conductor auth login` reads stdin.
- **Determinism matters.** No model decides which tool to call.

For exploratory work inside a conversation, the MCP tools are better: richer
results, no install.

## Commands

| Command | Answers |
|---|---|
| `conductor` | the resume point — what is in flight, what needs attention (same as `situation`) |
| `conductor fleet` | every server, its health and its apps |
| `conductor server show <id-or-name>` | one server in full; `--probe` adds live SSH checks |
| `conductor auth login \| status \| logout` | token management |
| `conductor version` | the build |

## Output

Every command returns the same envelope: `ok`, `data`, `summary`, `breadcrumbs`.

- Piped output is JSON; a terminal gets a table. `--json` forces JSON.
- `--jq '<filter>'` filters the envelope (implies `--json`).
- `--quiet` prints data only; `--agent` is agent-friendly output.
- **Breadcrumbs name the next command** and are guaranteed to exist — a test
  fails the build if one names an unregistered command or the wrong arity.

## Exit codes

Branch on these; they are a contract.

| Code | Meaning |
|---|---|
| 0 | ok |
| 1 | backend error |
| 2 | bad arguments or flags |
| 3 | no/invalid token |
| 4 | not found |
| 5 | forbidden |
| 6 | rate limited |
| 7 | could not reach Conductor |
| 8 | ambiguous context |

Errors are structured JSON on **stderr** in `--json` mode, never help text, and
render without the `--jq` filter so a broken filter cannot hide them.

## Configuration

`CONDUCTOR_URL` and `CONDUCTOR_MCP_TOKEN`, or `.conductor.json` in the working
directory or above, or `~/.conductor.json`. Precedence: flags > env > project
file > global file. `--verbose` reports which layer supplied each value.

The token resolves env > keyring. **There is no `--token` flag**, deliberately:
an argument is visible in `ps`, lands in shell history, and is written into an
agent transcript.

```sh
printf %s "$TOKEN" | conductor auth login
```

## Not here yet

Mutating commands (deploy, server lifecycle, domains, databases), profiles, and
a keyring file fallback. Use the MCP tools for those. `cli/API-COVERAGE.md` is
the current ledger.
