---
title: Deploy keys (alternative to the GitHub App)
description: Per-app read-only SSH deploy keys for cloning a private repo without a GitHub App.
order: 4
---

# Deploy keys

If you don't want to register a [GitHub App](connect-github), Conductor can use a per-app **read-only SSH deploy key** to clone a private repo. The App is recommended (cross-org, self-serve), but deploy keys are a simple self-hosted fallback.

## Generate a key

```
generate_deploy_key  app_name="Your App"
```

Conductor generates an ed25519 keypair, stores the private half encrypted, and returns the **public key**. (From the UI: the app page → **Deploy Key → Generate**.)

## Add it to GitHub

- **Automatic** — if you've stored an org GitHub token (`set_github_token`, a fine-grained PAT with *Administration: read/write*), Conductor adds the key to the repo for you. Nothing else to do.
- **Manual** — otherwise, copy the public key to the repo's **Settings → Deploy keys → Add deploy key**, leave **Allow write access unchecked** (read-only).

## Deploy

The deployer clones via the deploy key automatically (SSH URL + the materialized key). Clone-auth precedence is: **GitHub App token → deploy key → plain URL** — so if you later connect a GitHub App, it takes over with no per-app changes.
