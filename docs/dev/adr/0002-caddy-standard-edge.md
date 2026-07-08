# 0002. Caddy as Conductor's standard edge, superseding kamal-proxy

Date: 2026-07-09

## Status

**Rejected (2026-07-09).** The decision requires Conductor to reimplement
kamal-proxy's battle-tested zero-downtime deploy handoff (health-check → upstream
swap → drain) — reinventing proven 37signals functionality and owning a new class
of deploy-time reliability risk. Not worth it. **kamal-proxy stays as the edge and
keeps doing the handoff.** calm.page's dynamic-subdomain need is met by *adding*
Caddy narrowly / coexisting with kamal-proxy — never by replacing it (see below;
follow-up ADR / slot 18 revision). The analysis in Context stands and is why we
keep Caddy for native/docker + gain its Admin API where kamal-proxy can't reach —
but Caddy does **not** supersede kamal-proxy for Kamal apps.

## Context

Conductor manages three runtimes — Docker, Native, Kamal — but only **Kamal**
apps front with **kamal-proxy**. Native and Docker apps already sit behind
**Caddy** (driven by `CaddyClient` over the Caddy Admin API). So the fleet runs
**two edge models**, and kamal-proxy is the Kamal-only outlier.

**kamal-proxy** (Handbook §9, §13): one container per host, owns `:80/:443`,
routes by **static** host, issues Let's Encrypt certs for **configured** hosts,
and does the zero-downtime handoff automatically — on deploy it polls `/up`
(`healthcheck.interval` up to `deploy_timeout`), swaps traffic, and drains the old
container (`drain_timeout`). It is configured at **deploy time** (`deploy.yml
proxy:`); runtime control is limited to `kamal proxy boot/reboot/restart` over SSH.
It has **no** dynamic/wildcard host routing, **no** on-demand TLS, and **no** rich
runtime API. Cert issuance is single-server (§9).

**Caddy**: a runtime **Admin API** (add/remove routes, TLS — already used by
`CaddyClient`), **on-demand TLS** (issue certs for arbitrary hostnames on first
request, gated by an ask endpoint), and dynamic host routing. It does **not** know
about Kamal's blue-green container versioning, so the deploy-time upstream cutover
must be orchestrated by the caller.

**Driver:** calm.page needs dynamic per-tenant `*.calm.page` subdomains created
from a JSON payload — impossible on kamal-proxy, native to Caddy. It is not a
one-off exception; it is the first case that exposes kamal-proxy's ceiling.

## Decision

**Caddy becomes Conductor's standard edge across all runtimes, superseding
kamal-proxy.** Concretely:

1. Caddy owns `:80/:443` on the box. Each app publishes its app port to loopback;
   Conductor manages a Caddy route `host → reverse_proxy 127.0.0.1:<port>` (auto /
   on-demand TLS) via the Admin API. Kamal apps deploy with `proxy: false` +
   published port (depends on ADR 0001 for a real `deploy.yml`).
2. **Conductor owns the zero-downtime handoff** kamal-proxy did for free: on
   deploy, health-check the new container, then atomically repoint the Caddy
   upstream via the Admin API and drain the old. This is the one capability we
   take on, and it is shared with native/docker apps (which already need it).
3. The Caddy Admin API (`CaddyClient`) is the single, programmable edge-ops
   surface — routes, per-app subdomains, on-demand TLS — with no redeploy.

## Consequences

- **Positive:** one edge for all three runtimes (kamal-proxy was Kamal-only); the
  edge becomes programmable and Conductor-native (matches the whole product
  thesis); dynamic subdomains + on-demand TLS become possible (calm.page); cert
  issuance can be coordinated across the fleet rather than single-server.
- **Cost / risk (the crux):** Conductor must reimplement kamal-proxy's zero-downtime
  handoff (health-check → Admin-API upstream swap → drain). Bounded and one-time,
  but a botched swap/drain causes deploy-time blips. This must be built and tested
  carefully before any production box is migrated. kamal-proxy remains genuinely
  simpler and more reliable for the zero-config single-app case — Conductor is not
  that case.
- **Migration:** box-level (Caddy takes `:80/:443`; each app → `proxy: false` +
  published port + Caddy route), reversible. Depends on **ADR 0001** (real
  `deploy.yml` to emit `proxy: false`).
- **Reframes roadmap slot 18** (`per-app-proxy-mode`): it is not "per-app proxy
  choice" but "Caddy standard edge + deploy-time upstream cutover." The per-app
  dimension survives only as route/subdomain detail on the Caddy edge.

## References

- Kamal Handbook §9 (Kamal Proxy), §13 (Healthchecks) — kamal-proxy model + handoff.
- `app/services/caddy_client.rb` — existing Caddy Admin API client.
- ADR 0001 (self-describing deploys) — prerequisite for `proxy: false` emission.
- `docs/plans/per-app-proxy-mode.md` (slot 18) — to be revised to this decision.
