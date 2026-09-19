# API coverage

Conductor's MCP tools → CLI commands. In-scope endpoints stay at 100%; adding an
SDK method without its command and row is an incomplete change.

Scope for v1 is the **read** surface, plus token management.

Mutating tools (deploy, server lifecycle, domains, databases) remain out of
scope. Keyring auth now exists, which was the stated precondition, but the
second half of the argument still stands: a destructive command wants a
confirmation path and an audit story of its own, not just a safer token.

| Tool (action) | CLI command | Status |
|---|---|---|
| `conductor_read` (`fleet_status`) | `conductor fleet` | ✅ |
| `conductor_read` (`situation`) | `conductor situation` (also the default command) | ✅ |
| — (local) | `conductor auth login` / `status` / `logout` | ✅ |
| `conductor_read` (`server`) | `conductor server show <id-or-name>` (`--probe`) | ✅ |
| `conductor_read` (`app_logs`) | `conductor server logs` / `conductor app logs` | ⬜ |
| `conductor_read` (`deployment`) | `conductor deployment <id>` | ⬜ |
| `conductor_read` (`logs`) | — | ⬜ |
| `conductor_read` (`edge`) | — | ⬜ |
| `conductor_read` (`cloudflare`) | — | ⬜ |
| `conductor_read` (`transfer`) | — | ⬜ |
| `conductor_app` (all actions) | — | out of scope for v1 (mutating) |
| `conductor_app_config` | — | out of scope for v1 (mutating) |
| `conductor_server` | — | out of scope for v1 (mutating) |
| `conductor_domain` | — | out of scope for v1 (mutating) |
| `conductor_database` | — | out of scope for v1 (mutating) |
| `conductor_storage` | — | out of scope for v1 (mutating) |
| `conductor_cron` | — | out of scope for v1 (mutating) |
| `conductor_github` | — | out of scope for v1 (mutating) |
| `conductor_runbook` | — | out of scope for v1 |

`conductor server` closed the gap the scaffold left open, and `status` now emits
the per-server breadcrumb it had to withhold.
`TestEveryBreadcrumbNamesARegisteredCommand` enforces that mechanically — a
suggestion cannot outrun its implementation, and the check covers arity too, so
a crumb passing an argument to a command that takes none is caught as well.

Command names follow plan 09's table, not convenience: `fleet` (not `status`),
`situation` as the default command, and `server show` as a subcommand so
`server logs` can join it without breaking callers.

Next gap worth closing: `server logs`, the other question an operator asks after
`fleet` shows something is not running.
