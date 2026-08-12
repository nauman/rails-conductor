# Kamal/Caddy deployment cutover learnings

## Durable rules

- A repository that deploys from its base `config/deploy.yml` must not set
  `require_destination: true` or pass `-d production` unless the destination
  overlay is committed and available in that checkout. `KamalConfig` generating
  an overlay into an app checkout is a separate self-describing workflow; it
  does not make the Conductor repository's deploy workflow destination-aware.
- Pin Kamal to the tested minor series. `~> 2.10` allows Kamal 2.12; use
  `~> 2.10.1` when the fleet's shared kamal-proxy has not passed the 2.12
  compatibility requirement. A Kamal upgrade requires a planned proxy reboot,
  route republish, and host-by-host HTTP verification.
- `RemoteRailsRunner` must ask `KamalOps#available?` before routing a Kamal app
  through the Kamal harness. A Kamal deployment can have no checkout on the
  running container, so the Docker fallback is required for Conductor-managed
  containers that Kamal cannot answer.
- Caddy-mode cutover must publish every configured hostname for an app, not
  only its primary domain. Apex, `www`, and wildcard subjects are separate
  Caddy route matches; updating only one leaves stale traffic on the old
  container while health checks can still report green.
- `App#port` is the host-published infrastructure coordinate. `PORT` and the
  `runtime_port` fallback describe the listener inside the container and must
  never become a Caddy upstream. A Caddy container app without `App#port`
  refuses configuration, live-route mutation, and deploy before the incumbent
  is stopped.
- An existing primary or hostname-family route that disagrees with `App#port`
  is drift, not a cutover target. Fixed-port Caddy deploys do not change host
  ports between releases, so the pre-stop snapshot must refuse instead of
  rewriting the route after boot.
- `CADDY_PUBLISH_PORT` may remain as repo-specific ERB grammar, but
  `KamalDeployer` derives or removes it from the target edge and `App#port`.
  It is never an independent stored source of routing truth.
- A managed app's destination secrets must resolve `RAILS_MASTER_KEY` from the
  environment Conductor injects. Only a self-managed app may read
  `config/master.key`; that ignored file is deliberately absent from ordinary
  server-side checkouts.
- A custom alias outside the primary hostname family is owned only when its
  route is Conductor-managed and already targets the app's exclusive recorded
  host port. An unrelated legacy/no-id route on that port remains ambiguous and
  blocks the deploy.
- Select the deployer by deploy method before reasoning about the edge. A
  `deploy_method: kamal` app on a Caddy server still runs through
  `KamalDeployer`; Caddy changes placed only in `AppDeployer` will never execute
  for that production shape. Its fixed-port path needs a post-boot assertion.

## Deployment checklist

1. Confirm whether the workflow uses the repository base config or a generated
   destination overlay; do not mix the two contracts.
2. Confirm the exact Kamal lockfile series and the remote kamal-proxy version
   before deploying.
3. Exercise both Rails command paths: `kamal app exec --reuse` where the Kamal
   harness is available, and Docker fallback where it is not.
4. After Caddy cutover, inspect and verify every hostname associated with the
   app, including wildcard and alias routes, against the new live container.
5. Compare the recorded `App#port` with both Docker's published binding and the
   effective Caddy upstream. Correct drift before authorizing a deploy.

## Incident context

These rules were confirmed during the 2026-08-12 Conductor deployment. The
release was recovered by removing the unavailable destination requirement,
holding Kamal at the 2.10 series, and fixing the runner availability check.
The multi-host Caddy republish defect is enforced by the Kamal deploy
postcondition. Legacy routes are adopted in place, verification checks the
first effective route on the same Caddy server, and ambiguous hostname or
fixed-port ownership fails before the incumbent container is stopped. The
follow-up fix removed the runtime-port fallback after production records with
missing host ports would otherwise have reconciled healthy routes to unused
`127.0.0.1:3000`.
