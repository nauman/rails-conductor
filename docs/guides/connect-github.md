---
title: Connect GitHub
description: Set up the GitHub App once so Conductor can clone and deploy your private repositories across every org — no per-repo keys.
order: 3
---

# Connect GitHub

Conductor deploys your apps from their Git repositories. For **private** repos it needs read access to clone them. The clean, reusable way to grant that is a **GitHub App** — set up **once**, it works for **every repo across every org** you install it on, with short-lived tokens and no per-repo deploy keys.

## How it works (one App, many installations)

- **One** GitHub App is registered by whoever runs this Conductor instance (you, for self-hosted).
- You **install** that App on your GitHub org(s) — `intellectaco`, `pavelabs`, anything.
- Conductor stores the App's credentials once, then mints **short-lived installation tokens** to clone any repo the App can see.

> You never add keys per repository, and end-users never create their own App — they just install yours.

## 1. Create the GitHub App

1. Go to **<https://github.com/settings/apps/new>** (or your org's **Settings → Developer settings → GitHub Apps → New GitHub App**).
2. **GitHub App name:** `Conductor` (or `Conductor — yourcompany`).
3. **Homepage URL:** your Conductor URL, e.g. `https://conductor.pavelabs.io`.
4. **Webhook:** uncheck **Active** for now. (You'll enable it later for *auto-deploy on push*.)
5. **Repository permissions** — set only what's needed:
   - **Contents → Read-only** ← required, this is what lets Conductor clone/pull.
   - *Metadata → Read-only* is selected automatically.
   - (Later, for auto-deploy: **Webhooks**; for build status: **Commit statuses → Read and write**.)
6. **Where can this GitHub App be installed?** — "Any account" (or "Only this account" if it's just yours).
7. Click **Create GitHub App**. Note the **App ID** shown at the top.

## 2. Generate a private key

On the App's page, scroll to **Private keys → Generate a private key**. A `.pem` file downloads. Keep it safe — you'll paste its contents into Conductor once.

## 3. Install the App on your org(s)

1. On the App page, click **Install App** (left sidebar).
2. Choose the org (e.g. **intellectaco**), then **All repositories** (recommended — every current and future repo becomes deployable) or select specific repos.
3. Click **Install**. Repeat for any other orgs (e.g. `pavelabs`).

## 4. Give Conductor the credentials (once)

In Conductor, store the App so it can mint tokens. Either:

**From the UI:** Settings → Integrations → GitHub App → paste the **App ID** and **private key**.

**Or via an agent / MCP:**

```
set_github_app  app_id=<APP_ID>  private_key=<contents of the .pem>
```

Conductor validates the key and stores it encrypted. (The value is redacted from the audit log.)

## 5. Verify access

Confirm Conductor can see your repos:

```
github_installations
```

You should see your org(s) listed. To check a specific repo:

```
github_installations  repo=intellectaco/your-app
```

A `reachable: true` means Conductor can clone it.

## 6. Deploy

Now any app whose repository lives in an installed org just deploys — Conductor clones it with a fresh installation token at deploy time:

```
deploy_app  app_name="Your App"
```

No deploy keys, no tokens in config, nothing per-repo.

---

## Alternatives (when you don't want an App)

For a quick **self-hosted** setup without registering an App, Conductor also supports:

- **Deploy keys** — `generate_deploy_key` creates a read-only SSH key per app; add the public key to the repo's *Settings → Deploy keys*. See [Deploy keys](deploy-keys).
- **Personal access token** — `set_github_token` stores a fine-grained PAT (Administration: read/write) per org, which Conductor uses to auto-manage deploy keys.

The GitHub App is the recommended path: it's self-serve, cross-org, and the only one that scales to a multi-tenant cloud deployment (one App, each customer just clicks *Install*).
