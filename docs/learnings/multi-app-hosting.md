# Learning — Multi-App Hosting on One Box

> Captured from deploying real apps (Conductor, kuickr, wiseherds) onto one shared
> Hetzner box **by hand**. Each manual step below is a candidate Conductor UI feature —
> this doc is the blueprint for what the product should automate.

## The manual workflow (what we do today)

1. **Harden the server** — non-root `deploy` user (key-only sudo), `ufw` (22/80/443), `fail2ban`, `unattended-upgrades`, install Docker.
2. **Shared services on the box** — one **kamal-proxy** owns :80/:443 and routes every app by hostname; one **Postgres** cluster, a database + role per app.
3. **Per app:**
   - Create a **DB role + database** on the shared Postgres (role needs `CREATEDB` so `db:prepare` can make the cache/queue/cable DBs).
   - Generate the **deploy config**: ride the shared proxy (`proxy.host`), shared registry, `DB_HOST` → the shared Postgres container.
   - Provide **secrets**: `RAILS_MASTER_KEY`, DB password, registry token.
   - **Build → push → deploy**; `db:prepare` creates the databases on first boot.
   - Add the **DNS A record** → the box IP (grey cloud) so Let's Encrypt issues TLS.

## Gotchas (hard-won)

- **Kamal builds from the git `HEAD` clone, not the working dir.** Uncommitted `credentials.yml.enc` / `deploy.yml` won't be in the image. Symptom: `ActiveSupport::MessageEncryptor::InvalidMessage: AEAD authentication tag verification failed` at boot, because the baked credentials don't match the runtime `RAILS_MASTER_KEY`. **Fix: commit before deploy.**
- **Lockfile platforms** — `Gemfile.lock` must list `x86_64-linux` for an amd64 server build (`bundle lock --add-platform x86_64-linux`).
- **Private gems break the build** — a Gemfury/private source (e.g. `rapid_rails_ui`) needs either a build secret or removal.
- **Missing `master.key`** — regenerating creates a new key (and drops old encrypted credential values); store keys centrally (we use the `intellectaco` localvault, `<APP>.master_key`).
- **Shared Postgres** — the app's role must own its database and have `CREATEDB`.
- **Cloudflare proxy (orange cloud)** — kamal-proxy's Let's Encrypt (HTTP-01/TLS-ALPN) breaks behind the proxy. Use **grey cloud** for LE, or a **Cloudflare Origin Certificate** on the proxy, or per-app Caddy with **DNS-01** (needs its own ports → own box).

## → Conductor feature opportunities

| Manual step | Conductor feature |
|---|---|
| Create DB role + database on the cluster | **Database** resource (Hatchbox-style): provision/drop per-app DBs + credentials on a server's Postgres cluster |
| Hand-write `deploy.yml` for the shared box | **Deploy config generator** (shared proxy host, registry, DB binding) |
| `cat master.key`, generate DB passwords | **Secrets**: master-key + DB-password storage (vault integration) |
| Add DNS A record by hand | **DNS automation** (Cloudflare provider) |
| `kamal build/push/deploy` per app | **One-click deploy** with live streaming (already partly there) |
| Commit-before-deploy gotcha | **Pre-deploy checks**: warn on uncommitted credentials/config |

See `docs/plans/multi-tenancy.md` and the Postgres-cluster idea for where these land.
