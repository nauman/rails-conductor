---
title: Deploy an app
description: Deploy method choices (kamal / native / docker) and how a deploy runs through Conductor.
order: 2
---

# Deploy an app

## Choose a deploy method

| Method | What it does | When to use |
|---|---|---|
| **kamal** | Conductor runs Kamal as the **control machine** (in its own container): clones your repo, builds on the target's docker daemon over SSH, and deploys. You keep `kamal logs` / `kamal console`. | Containerized apps you want on Kamal. |
| **native** | Git-based release over SSH on the box: `app-setup` → `systemd-setup` → `app-deploy` (Puma + systemd). | Hatchbox-style native Rails apps. |
| **docker** | Build + run a container directly. | Simple container apps. |

Set the method on the app (UI **Edit app**, or the `update_app` MCP tool).

## What a deploy does

Triggering a deploy (the **Deploy** button, or the `deploy_app` MCP tool) creates a `Deployment` and dispatches by method:

1. **Clone / sync** the repo to the target commit (using your [GitHub connection](connect-github) for private repos).
2. **Build** the release (Kamal builds on the target's daemon over SSH — no docker socket mounted into Conductor).
3. **Release** + health-check, then mark the deployment succeeded or failed.

Watch progress live:

```
deployment_log  app_name="Your App"        # status + log
deployment_log  deployment_id=123 tail=50  # last 50 lines
```

## Environment variables

Set per-app env in Conductor (UI, or `set_env_variable`). For **kamal** apps, Conductor generates `.kamal/secrets` from these at deploy time — so the UI is the source of truth for values like `SECRET_KEY_BASE` and `DATABASE_URL`. For **native/docker**, they're exported into the release.

## Status

Conductor reflects the live container state — `fleet_status` (and the dashboard) show each app as `running` / `stopped`. For Kamal apps it detects the container by its `service` label; trigger a check with `sync_app_status`.

## Rolling back

Kamal retains prior image versions (`kamal rollback`); native release-dir rollback is on the [roadmap](/docs). Until then, redeploy a known-good commit.
