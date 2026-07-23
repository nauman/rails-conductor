# Learning — Static assets 404 when a Kamal app sits behind a host reverse proxy

> Captured after two apps on the same host rendered unstyled: every
> `/assets/*.css` / `*.js` returned **404**, even though the files were present
> in the image. The apps ran as independent Kamal containers (no kamal-proxy)
> behind a host **Caddy** edge that only reverse-proxies. The fix is one env var,
> and the point of this note is to make that a **per-app runbook item** so the
> next asset-404 is a 30-second diagnosis.

## Symptom

- Pages load (HTML 200) but are unstyled — no CSS/JS applied.
- The HTML references fingerprinted assets (`/assets/application-<hash>.css`), so
  the manifest is fine, but each asset URL returns **`404 text/html`** (the Rails
  404 page, not a static file).

## Why it happens

Two facts combine:

1. **Nothing external serves `/assets`.** With the host-Caddy edge pattern
   (`servers.web.proxy: false` + a published host port + a Caddy `reverse_proxy`
   route), Caddy forwards *every* path to the app. It does not serve the app's
   `public/assets` from disk. So the app must serve its own static files.
2. **Rails' static file server is off by default in production.** The generated
   `config/environments/production.rb` has:

   ```ruby
   config.public_file_server.enabled = ENV["RAILS_SERVE_STATIC_FILES"].present?
   ```

   If `RAILS_SERVE_STATIC_FILES` is unset, `public_file_server` is disabled →
   Puma 404s `/assets/*`, and Thruster (which proxies to Puma) returns that 404.
   The precompiled files are right there in `public/assets` — nobody is allowed
   to serve them.

Confirm it in one shot inside the container — the file exists but both ports 404:

```bash
docker exec <web> ls -la /rails/public/assets/application-*.css      # present
docker exec <web> curl -s -o /dev/null -w '%{http_code}\n' localhost:80/assets/<file>   # 404 (thruster)
docker exec <web> curl -s -o /dev/null -w '%{http_code}\n' localhost:3000/assets/<file> # 404 (puma)
docker exec <web> sh -c 'echo $RAILS_SERVE_STATIC_FILES'             # empty → the bug
```

## Fix

Set the flag in the app's clear env and redeploy (env-only change):

```yaml
# config/deploy.yml
env:
  clear:
    RAILS_SERVE_STATIC_FILES: "true"   # app serves its own /assets; Caddy only proxies
```

Then a normal `kamal deploy` (or push env + boot). Assets return 200 with a long
cache TTL. Any app deployed with `proxy: false` behind a reverse proxy that does
not itself serve `public/` needs this — it is not platform-specific.

## Two gotchas when applying the fix

1. **Redeploy can't blue-green with a fixed host port.** A `proxy: false` role that
   publishes a fixed port (e.g. `9050:80`) can't boot a new container while the old
   one holds that port — `kamal deploy` fails with `Bind for 0.0.0.0:9050 failed:
   port is already allocated`. Apply env/image changes with a brief-downtime swap:
   `kamal app stop && kamal app boot` (seconds). The first deploy works because
   there's no old container to conflict with.
2. **Cloudflare caches the 404.** Assets are cacheable, so a proxied CDN (Cloudflare)
   will have cached the pre-fix `404`. After the origin serves `200`, the edge may
   still return the stale `404` until its TTL lapses or you purge — verify against
   the origin (`curl --resolve <host>:443:<origin-ip> …`) before assuming the fix
   failed, and purge the CDN cache (or append `?v=` to confirm) if needed.

## Runbook / feature blueprint

- **Per-app runbook:** add a "Known errors → fixes" entry: *unstyled page /
  `/assets` 404 → set `RAILS_SERVE_STATIC_FILES=true` and redeploy.*
- **Deploy checklist:** after any first deploy onto a proxy-less host, verify an
  asset URL returns `200`, not just that `/up` is green.
- **Conductor feature idea:** a post-deploy smoke check that fetches one
  referenced asset and flags a 404 — the same "surface the trap" goal as the
  fleet edge-type detection.
