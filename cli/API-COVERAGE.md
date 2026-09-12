# API coverage

Conductor's MCP tools → CLI commands. In-scope endpoints stay at 100%; adding an
SDK method without its command and row is an incomplete change.

Scope for v1 is the **read** surface. Mutating tools (deploy, server lifecycle,
domains, databases) are deliberately out of scope until auth moves to the
keyring — a destructive command should not be one env var away from running.

| Tool (action) | CLI command | Status |
|---|---|---|
| `conductor_read` (`fleet_status`) | `conductor status` | ✅ |
| `conductor_read` (`situation`) | `conductor situation` | ✅ |
| `conductor_read` (`server`) | `conductor server <id>` | ⬜ |
| `conductor_read` (`app_logs`) | `conductor logs <app>` | ⬜ |
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

`conductor server <id>` is the most-wanted gap: `status` would naturally suggest
it for an offline box, and deliberately does not, because a breadcrumb naming a
command that does not exist is a defect. `TestEveryBreadcrumbNamesARegisteredCommand`
enforces that mechanically — a suggestion cannot outrun its implementation.
