# Per-App Caddy Edge (Proxy Mode) Plan — Roadmap Slot 18

## Pillar
Routing and edge

## Status
Proposed (spec, 2026-07-09). Roadmap: `docs/roadmap/18-per-app-proxy-mode.html`. Siblings: `routing-caddy.md`, `caddy-client.md`. Hard dependency: ADR `docs/dev/adr/0001-self-describing-kamal-deploys.md`.

## Current Reality

- Kamal apps front with **kamal-proxy**: the `proxy:` block in `config/deploy.yml` owns `:80/:443`, terminates TLS (Let's Encrypt), and routes by host to the app container.
- `CaddyClient` already speaks the Caddy Admin API over SSH — `upsert_route` / `remove_route` / `fetch_managed_routes` on routes tagged `conductor-route-*`. So Conductor can publish/withdraw a Caddy reverse-proxy route today.
- Native/Docker route wiring is partial (`routing-caddy.md`).
- **No per-app edge selection, no migration flow.** `app-two.example.com` needs Caddy but (a) its `deploy.yml` is still placeholder (`app-two` — the ADR 0001 truth-gap) and (b) it shares a box with other kamal-proxy apps.

## The one hard constraint (read before designing)

`:80/:443` is a **box-level** resource. **Caddy and kamal-proxy cannot both own `:80/:443` on the same host.** On the shared fleet box (multiple Kamal apps behind one kamal-proxy), "put app-two.example.com on Caddy" is therefore **not a per-app toggle in isolation** — it is a **box-edge decision**. This spec models the edge at the **Server** level, with per-app route/publish details, and a guided migration that flips a whole box.

## Goal

Make **Caddy a first-class, selectable edge**: a server declares its edge (Caddy or kamal-proxy), apps on a Caddy server are published to loopback and served by Caddy (TLS, host routing, wildcard subdomains), and Conductor can **migrate a box from kamal-proxy to Caddy safely and reversibly** — so `app-two.example.com` (and any app) moves with confidence, reproducibly from the repo.

## Why This Plan Exists

- Standardizing on Caddy: one edge per box, automatic TLS, and per-app subdomains driven by a JSON payload (the app-two.example.com requirement).
- kamal-proxy is per-service and contends for `:80/:443`, so it does not compose with Caddy on shared boxes.
- Migration is manual and risky today; it should be a Conductor capability with verify + rollback.

## Scope

- `Server#edge` mode: `caddy | kamal_proxy` (who owns `:80/:443` on the box).
- Deploy-artifact behaviour by edge (all three runtimes):
  - **caddy edge** → app publishes to loopback (`127.0.0.1:<hostport>`), and Conductor upserts a Caddy route `host → reverse_proxy 127.0.0.1:<hostport>` (auto-TLS). Kamal apps deploy with `proxy: false` + `ports: ["127.0.0.1:<hostport>:<containerport>"]`.
  - **kamal_proxy edge** → keep the `proxy:` block (status quo).
- `EdgeMigrator`: box-level kamal-proxy → Caddy cutover with preflight, verify, rollback.
- Wildcard / per-app subdomains via the Caddy Admin API (JSON payload).
- Reachability + certificate status surfaced per app.

## Non-goals

- Running Caddy **and** kamal-proxy on `:80/:443` simultaneously (impossible).
- Arbitrary reverse proxies (nginx/Traefik) — Caddy and kamal-proxy only.
- Multi-region / global edge routing.
- Automatic zero-downtime for the box-edge swap in v1 (aim for a short, verified cutover window; document it).

## Design

### Data model
- `servers.edge` : string, `{"caddy","kamal_proxy"}`, default `"kamal_proxy"` (existing boxes) / `"caddy"` (new). Caddy admin port already modelled (`Server#caddy_admin_port`, 2019).
- Reuse `App#port` as the container port; add `apps.host_port` (loopback publish) if it must differ.
- Optional `apps.subdomains` (array) for wildcard/route fan-out; managed Caddy routes stay `conductor-route-*` tagged.

### Deployer changes (honour `server.edge`)
- **KamalDeployer** (caddy edge): generate `proxy: false` + publish `127.0.0.1:<hostport>:<containerport>` in the **real** `deploy.yml` — this is why the plan **depends on ADR 0001** (Conductor must write a truthful deploy.yml, not placeholder ERB). After deploy, `CaddyClient.upsert_route`.
- **AppDeployer** (Docker, caddy edge): `docker run -p 127.0.0.1:<hostport>:<containerport>` + upsert route.
- **NativeDeployer** (caddy edge): Puma already binds loopback; just upsert route.
- kamal_proxy edge: unchanged.

### EdgeMigrator (new service) — box kamal-proxy → Caddy
1. **Preflight**: Caddy installed + Admin API reachable (`CaddyClient.health_check`); enumerate all apps on the box; snapshot current Caddy + kamal state.
2. **Republish**: redeploy each app in caddy mode (publish loopback port, `proxy:false`) *while kamal-proxy still serves* — apps now listen on both paths.
3. **Cutover**: stop kamal-proxy (frees `:80/:443`) → start Caddy on `:80/:443` with all managed routes → wait for TLS issuance.
4. **Verify**: each host returns 200 over HTTPS with a valid cert; else **rollback** (restart kamal-proxy, revert `edge`).
5. **Retire**: remove kamal-proxy container once verified. Leave no stale routes.

### UI
- **Server**: an "Edge" setting (Caddy | kamal-proxy) + a **"Migrate to Caddy"** action carrying the explicit *"this flips the whole box"* warning.
- **App**: shows edge, its Caddy route, TLS/reachability status.

## Core Workflows
1. New app on a Caddy-edge server → deploy → Caddy serves it on `:443` with valid TLS; kamal-proxy uninvolved.
2. **Migrate app-two.example.com's box to Caddy** → every app republished + routed via Caddy, kamal-proxy retired, reversible on failure.
3. Add `*.app-two.example.com` wildcard / per-subdomain routes via the Admin API JSON payload.
4. Move an app between servers → routes follow, no stale entries (shared with `routing-caddy.md`).

## Acceptance
- Set `server.edge = caddy`, deploy an app → HTTPS 200 via Caddy, valid cert, no kamal-proxy.
- Run the migration on app-two.example.com's box → all apps served by Caddy, kamal-proxy gone, zero stale routes, rollback proven on an injected failure.
- `kamal console -d production` / `kamal app logs` still work from the repo (ADR 0001) regardless of edge.
- `*.app-two.example.com` resolves through a Caddy route created from a JSON payload.

## Phases (finish-workflow — ship all)
- **P1** — `Server#edge` model + deployers honour it (publish loopback port + `CaddyClient.upsert_route` on caddy edge). Tests: deploy in caddy mode upserts the expected route; kamal_proxy mode unchanged.
- **P2** — `EdgeMigrator` (box kamal-proxy→Caddy) with preflight/verify/rollback + Server UI action. Tests: migration path, rollback path.
- **P3** — wildcard subdomains via Admin API JSON + cert/reachability status per app.
- **P4** — docs (`ARCHITECTURE.md` edge section, `routing-caddy.md` cross-link), roadmap slot 18 → In progress/Done, plans INDEX row.

## Risks / Open questions
- **Cutover downtime**: publishing ports first keeps the window to just the proxy swap; document it. Zero-downtime swap is a v2 refinement.
- **Shared box blast radius**: migrating one app forces the box — the UI must make this unmissable.
- **TLS timing**: Let's Encrypt issuance on cutover; consider pre-issuing or a staged verify.
- **Hard dependency on ADR 0001** — without a real `deploy.yml`, Conductor can't reliably emit `proxy:false` + published ports. Sequence ADR 0001 first (or together).
- Do we keep true *per-app* proxy mode within a box, or accept edge-per-box? This spec says **edge-per-box** (honest to `:80/:443`); per-app is expressed as route/publish detail on a Caddy box.
