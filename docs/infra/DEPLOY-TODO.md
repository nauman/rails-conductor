# Deployment TODOs

These are the remaining Kamal command integrations. Conductor must answer from
the app's declared edge, not blindly run a Kamal command whose implementation
assumes kamal-proxy.

## Edge command adapter

### Container reuse invariant

- [x] **Preserve the live-container contract on Caddy boxes.**
  - Rails console, runner, migrations, diagnostics, and other app commands must
    use `kamal app exec --reuse`.
  - Logs use `kamal app logs` (Kamal 2.12 has no `logs --reuse` flag); logs do
    not create containers.
  - The Caddy ops path must never call `kamal app boot`, `kamal app start`, or
    generic `kamal redeploy`, because those can create or replace containers.
  - A new container is permitted only inside an explicitly authorized deploy or
    rollback transaction, never as a side effect of console/runner/health read.
  - Acceptance: command tests assert `--reuse` and prove no app command invokes
    `boot`, `start`, or an unapproved deploy path.

- [x] **`kamal proxy` — rewire as an edge operation.**
  - Kamal-proxy server: delegate the supported proxy action to Kamal.
  - Caddy server: use `CaddyClient`/`Edge::CaddyAdapter`; never start or manage
    kamal-proxy and never bind `:80`/`:443` from Kamal.
  - Acceptance: a Caddy app can inspect/reconcile its route without executing
    `kamal proxy`; a Kamal-proxy app preserves its existing route behavior.

- [x] **`kamal redeploy` — replace with an edge-safe redeploy ritual.**
  - Kamal-proxy server: use Kamal's deploy/redeploy lifecycle and `/up` health
    gate.
  - Caddy server: use the Caddy-mode Kamal deploy configuration (`proxy: false`,
    loopback publish, Docker healthcheck) and the existing stop-first recovery.
  - Do not call Kamal's generic `redeploy` command on Caddy: Kamal documents it
    as booting kamal-proxy.
  - Acceptance: no Caddy redeploy starts `kamal-proxy`; a failed Caddy boot
    attempts recovery and leaves an explicit health result.

- [x] **`kamal app maintenance` — rewire to Conductor maintenance state.**
  - Kamal-proxy server: Kamal maintenance may be used only when it targets the
    app's Kamal proxy route.
  - Caddy server: persist an app maintenance flag and have Caddy return a
    controlled 503 for that app route; do not invoke Kamal maintenance.
  - Acceptance: entering/exiting maintenance is audited, scoped to one app,
    reversible, and does not alter unrelated Caddy routes.

- [x] **`kamal app live` — rewire to the same edge adapter.**
  - Kamal-proxy server: delegate to Kamal live mode.
  - Caddy server: clear the Conductor maintenance flag and restore the desired
    Caddy route after verifying the app health endpoint.
  - Acceptance: live mode refuses to restore traffic when the app is unhealthy.

- [ ] **Universal command policy and tests.**
  - Centralize command classification (`read`, `app mutation`, `edge mutation`,
    `deploy`) and require an explicit actor/authorization for mutations.
  - Jazari/agents may use read-only Kamal operations and health inspection, but
    cannot invoke deploy/redeploy or edge mutations implicitly.
  - Add contract tests proving Caddy mode never runs `kamal proxy`, generic
    `kamal redeploy`, `kamal app maintenance`, or `kamal app live`.

- [x] **Caddy multi-host cutover.**
  - **Implementation boundary:** Caddy-edge apps with `deploy_method: kamal`
    run through `KamalDeployer`, not `AppDeployer`. The fixed-port assertion
    belongs in KamalDeployer after boot; implementing it only in AppDeployer is
    an incomplete fix that production will never execute for those apps.
  - Republish every configured hostname for an app during Caddy-mode cutover,
    including apex, `www`, aliases, and wildcard subjects.
  - Do not rely only on Conductor `@id`: adopt a legacy/no-id route in place,
    verify the first effective route per server, and fail before stop when
    hostname or fixed-port ownership is ambiguous.
  - `App#port` is mandatory for Docker/Kamal apps on Caddy. Never substitute
    `runtime_port`/`PORT`: those are container listeners, not host upstreams.
    A managed custom alias may follow only when it already targets that recorded
    port; unrelated legacy/no-id routes fail closed.
  - A non-empty primary/family route on a different upstream is also a hard
    pre-stop failure. `CADDY_PUBLISH_PORT` is adapter grammar derived from
    `App#port`, and is stripped on kamal-proxy targets so stale edge state cannot
    follow an app during transfer.
  - Acceptance: no hostname remains attached to the superseded container after
    a successful deploy, and each hostname is verified against the new release.

- [x] **Keep Kamal grammar behind one gateway.**
  - Application services call the Conductor-owned `KamalGateway` DSL only.
  - `KamalCommand` is an internal translation layer covered by version contract
    tests; no service may assemble Kamal flags or shell syntax directly.
  - A Kamal upgrade changes the gateway adapter/tests first, while Caddy,
    deployment policy, and Rails operations retain their stable interfaces.

- [ ] **Kamal 2.12 upgrade — needs a proxy-reboot window (operator).**
  - 2.12 refuses to deploy against a kamal-proxy older than v0.9.2 and instructs
    you to run `kamal proxy reboot`. The gem is therefore held at `~> 2.10.1`;
    `~> 2.10` does NOT hold it, since that permits 2.12.
  - Why it is a window and not a bump: the proxy is shared. It holds the routes
    for several public hosts, and a reboot drops every one of them until each app
    re-registers — and an app whose route was published by a non-kamal path will
    not re-register on its own.
  - Sequence: raise the pin and `minimum_version` together → `kamal proxy reboot`
    → re-publish every route on that box → verify each host serves 200 → only
    then raise `KamalCommand::MINIMUM_VERSION`.
  - Acceptance: every host the proxy served before the reboot serves 200 after,
    and `kamal-proxy --version` reports ≥ v0.9.2.

- [x] **Adopt placeholder Caddy app repository configs before deploy.**
  - Any committed `config/deploy.yml` with placeholder host/image values or
    kamal-proxy enabled on a Caddy target must be refused safely before stop.
  - Populate its registry/secrets coordinates, then either commit a truthful
    Caddy-mode config or enable and verify the self-describing destination
    overlay. Do not force through the existing guard.
  - Verified in production with an adopted private app: explicit `proxy: false`,
    SHA release tag, loopback fixed-port publish, managed secrets, Caddy route
    reconciliation, and post-replacement logs plus `app exec --reuse`.

## Deploy execution topology

- [ ] **Separate build execution from roll execution.**
  - A production serving host must not also be the BuildKit worker. Building one
    app there can starve every app sharing that host.
  - Build on CI, a control machine, or a dedicated builder; push the immutable
    `linux/amd64` image to the registry; let the target host only pull, boot,
    health-check, and cut over that finished image.
  - Model `build_executor` and `roll_executor` independently. Refuse a serving
    host as the builder by default; an emergency override must be explicit,
    audited, and protected by a capacity preflight.
  - Acceptance: routine deploys never set a remote Docker/BuildKit endpoint to
    the target serving host, and a resource audit proves no build workload runs
    there during rollout.
  - Immediate safety landed after consecutive fixed-port build failures: Caddy
    apps finish `kamal build push` before stopping the incumbent, then run
    `kamal deploy --skip-push`; rollback verifies the exact requested container
    is running. This prevents build failure becoming downtime but does not close
    this item — BuildKit still needs a dedicated off-host executor.

- [ ] **Make external release reporting verifiable and retryable.**
  - The signed `POST /webhooks/:app_id/deployment` receiver and operator UI
    already exist. External deploy templates must receive the endpoint, app id,
    and per-app HMAC secret, then report success or failure with the exact SHA.
  - A missed or rejected report must be visible and retried; it must not leave a
    successful live roll represented by a stale Conductor release record.
  - Acceptance: an external roll produces one idempotent deployment record for
    its SHA, reports authentication/network failures distinctly, and Conductor
    reconciles a live-but-unreported SHA without guessing it is the prior
    release.

## Current audit snapshot

Already wired: `kamal app logs`, `kamal app exec --reuse`, Rails console,
`kamal app details`, Kamal deploy, Kamal rollback, Caddy-mode role health
configuration, the edge-aware command gateway, and the authorized UI/MCP
command surface. Production audit/event records for maintenance changes remain
a separate follow-up.
