---
name: conductor
description: Use to operate a self-hosted Rails fleet through Conductor's MCP server — checking fleet status and logs, registering servers/clusters, creating/updating/deploying apps, provisioning databases, managing Caddy domains and env vars, and wiring GitHub access. Fires on fleet/server/deploy/route/database framing when Conductor is the control plane. These are real infrastructure actions on owned servers — confirm before destructive or outward-facing ones.
---

# Conductor (fleet via MCP)

Endpoint `/mcp` — `GET /mcp/list` to discover the live tool set, `POST /mcp/call` to invoke. Auth: Bearer `CONDUCTOR_MCP_TOKEN` (503 if unset). Calls run as the first admin user. Tool defs come from `ToolRegistry` (`app/tools/tool_registry.rb`); always trust `/mcp/list` over this doc if they differ.

## Tools (18, grouped)

**Observe (safe, run first to orient)**
| Tool | Use for |
|------|---------|
| `fleet_status` | All servers + apps + health metrics. Orient here first. |
| `recent_logs` | Recent script-run / deployment logs for a server or run. |
| `deployment_log` | One deployment's status + output (by `deployment_id`, or `app_id`/`app_name` for latest). Watch a deploy triggered via `deploy_app`. |
| `sync_app_status` | SSH-check an app's live container status and update Conductor's record (docker/native/kamal). |
| `github_installations` | List orgs/users where Conductor's GitHub App is installed; check repo reachability before deploying. |

**Mutate apps & deploys (confirm first)**
| Tool | Use for |
|------|---------|
| `create_app` | Create an app (docker/native), optionally domain/port/branch/notes. |
| `update_app` | Change deploy method, repo, branch, domain, port, notes. |
| `deploy_app` | Deploy to latest commit; dispatches by `deploy_method` (native/docker/kamal). |
| `run_script` | Run a provisioning/deploy script; creates a ScriptRun + enqueues job. |
| `set_env_variable` | Create/update an env var on an app. |

**Infrastructure (confirm first — outward-facing / destructive)**
| Tool | Use for |
|------|---------|
| `register_server` | Add a host to the fleet. |
| `register_database_cluster` | Register a running Postgres container as a cluster. |
| `provision_database` | Create role+db+password on a cluster; returns connection URL. |
| `add_domain` | Add a Caddy domain routed to an app socket/port. |
| `remove_domain` | Remove a Caddy domain. Destructive — confirm. |

**GitHub access wiring (stores credentials)**
| Tool | Use for |
|------|---------|
| `generate_deploy_key` | Make a read-only deploy key for an app's private repo; returns PUBLIC key to add on GitHub. |
| `set_github_token` | Store an org GitHub token (fine-grained PAT or App installation token). |
| `set_github_app` | Configure Conductor's GitHub App (app_id + PEM); Conductor-wide. |

## Flow
1. `fleet_status` to orient → `recent_logs`/`deployment_log` to diagnose.
2. Mutating app config, deploying, provisioning DBs, changing domains, or storing credentials are real infra actions on owned servers — **confirm with the user before each**, especially `remove_domain`, `provision_database`, and the GitHub credential tools.
3. After `deploy_app`, poll `deployment_log` to confirm success.

Setup: the Conductor MCP server must be connected in the session (see `docs/USAGE.md` "MCP Server"). The skill assumes that connection exists.
