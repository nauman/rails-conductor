# Conductor's deploy lock is stranded by its own self-deploy

**Found:** 2026-07-31 · **Status:** open · **Impact:** every Conductor CI deploy
fails until someone releases the lock by hand

## Symptom

`Deploy Conductor` runs fail at the `kamal deploy` step with:

```
Acquiring the deploy lock...
Deploy lock already in place!
Locked by:  at 2026-07-30T16:07:07Z
Message: Automatic deploy lock
ERROR (Kamal::Cli::LockError): Deploy lock found.
```

Three runs failed this way on 2026-07-30 (13:52, 15:00, 16:05). The holder name
is blank and the timestamp never advances — it is a **stranded** lock, not
contention. Once stranded, every subsequent deploy fails until it is released.

## Root cause: two deploy paths race for one lock

Conductor is deployed **twice** for the same commit:

1. **GitHub Actions** — `.github/workflows/deploy.yml` on push to `main`.
2. **Conductor itself** — the GitHub webhook fires `WebhooksController`, which
   deploys any app with `auto_deploy?` on (`app/controllers/webhooks_controller.rb:16`).
   Conductor is registered as one of its own apps, so it deploys itself through
   `KamalDeployer`.

Evidence for path 2 on the failing push: deployment **213**, app `Conductor`,
commit `c1cd377`, "succeeded" at 16:07:14 — an in-product deployment record that
CI does not create. The stranded lock is timestamped 16:07:07, seven seconds
earlier.

Path 2 is the classic self-deploy inversion: `kamal deploy` runs *inside* the
container it is replacing. Kamal takes the lock, stops the old container, and its
own process dies before the `ensure` block that releases it. The app comes back
up (so Conductor records "succeeded"), and the lock stays behind forever.

The workflow's own header comment says this must not happen:

> Conductor (the backbone) deploys itself via CI — a clean control machine — NOT
> via in-product self-deploy. This sidesteps the self-deploy inversion entirely:
> no self-kill, no stranded kamal locks, no rebuilding secrets from the DB.

That is the intended design. The in-product path is still enabled, so the
design is documented but not enforced.

## Contributing bug: CI has no stale-lock recovery, though Conductor does

`KamalDeployer#run_kamal_deploy` (`app/services/kamal_deployer.rb:414`) already
handles exactly this, with a correct argument for why it is safe:

```ruby
if result.output.to_s.include?("Deploy lock found")
  log "Stale kamal deploy lock detected (a prior deploy was killed mid-run). Releasing and retrying once."
  @shell.run(*kamal_lock_release_command, ...)
  result = @shell.run(*kamal_command, ...)
end
```

`.github/workflows/deploy.yml:109` runs a bare `bin/kamal deploy` with no such
recovery. So the fleet's deployer self-heals, while the path that ships Conductor
itself does not — even though Conductor is the app most likely to strand a lock.

## Contributing bug: the concurrency comment claims a guarantee it can't give

```yaml
# Never run two production deploys at once (this is what prevents lock contention).
concurrency:
  group: deploy-conductor-production
  cancel-in-progress: false
```

A GitHub concurrency group serializes **GitHub Actions runs**. It has no
visibility into the in-product deploy path, which is where the competing deploy
actually comes from. The comment asserts a guarantee the mechanism does not
provide, which is how this went unnoticed.

## Fixes, in order of value

1. **Turn `auto_deploy` off for Conductor's own app record.** One field, and it
   removes the race at the source. CI becomes the single deploy path, matching
   the documented design.
2. **Add stale-lock recovery to the CI step** — the same detect / release /
   retry-once as `KamalDeployer`, so a stranded lock self-heals instead of
   blocking every deploy until a human intervenes.
3. **Guard the self-deploy path in code**: refuse (or hand off to CI) when the
   app being deployed is the one running the deployer. A comment in a workflow
   file cannot enforce an invariant about a different code path.
4. **Correct the concurrency comment** to say what it actually covers.

## Recovery today

Manual, on the box:

```bash
cd <conductor checkout> && bin/kamal lock release -d production   # modifies state
```

Then re-run the failed workflow.

## Related

- `docs/dev/adr/0001-self-describing-kamal-deploys.md`
- Memory: "self-deploy reconciliation" — the boot reconciler that marks these
  self-killed deploys as succeeded, which is why they look fine in the UI.
