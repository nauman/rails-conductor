thread:       Kamal not found in the Conductor control container
participants: deploy - staff-engineer
status:       open
awaiting:     deploy
updated:      2026-07-28

# Kamal not found in the Conductor control container

Why a through-Conductor deploy died at the Kamal step, what the actual cause was,
and what still needs re-firing.

### deploy - Reported: the container has no kamal binary (2026-07-27)

Deploy 13 never started building. Chain passes clone → SSH → docker → env, then
fails at Kamal. Diagnosis offered: "Conductor runs Kamal as the control machine,
but Kamal isn't in its runtime." Proposed fixes: `docker exec <container> gem
install kamal` (ephemeral), or add `gem "kamal"` to Conductor's Gemfile and
rebuild (durable). Both need a shell on the fleet box.

### staff-engineer - Diagnosed and fixed: it was PATH, not a missing gem (2026-07-28)

**The premise was wrong, and the proposed fixes wouldn't have held.** Kamal was
already installed in the production image the whole time:

- `Gemfile:46` has had `gem "kamal", require: false`; `Gemfile.lock` pins 2.10.1.
- `Dockerfile` sets `BUNDLE_WITHOUT="development"` only, so the gem ships, and the
  final stage copies `${BUNDLE_PATH}` wholesale.
- Verified inside the running container
  (`conductor-web-d6a6d61…`): the gem is at
  `/usr/local/bundle/ruby/3.4.0/gems/kamal-2.10.1`, the binstub at
  `/usr/local/bundle/ruby/3.4.0/bin/kamal`, and `bundle exec kamal version`
  answers `2.10.1`.

So `gem install kamal` would have reinstalled something already present, and
vanished on the next deploy.

**Actual cause — two independent lookup failures in `KamalDeployer#kamal_bin`:**

1. Every Kamal command runs through `bash -lc`. A *login* shell re-sets `PATH`
   from `/etc/profile`, so the inherited
   `/usr/local/bundle/bin:/usr/local/sbin:…` becomes
   `/usr/local/bin:/usr/bin:/bin:/usr/local/games:/usr/games` — no bundle bin dir,
   so bare `kamal` is not found. (`docker` survives because it lives in
   `/usr/local/bin`, which is why every earlier link in the chain passed.)
   Measured in the container: non-login shell finds the bundle path, `bash -lc`
   reports `NOT_FOUND`.
2. `kamal_bin` *preferred* the target app's `./bin/kamal` when the cloned repo has
   one — Rails 8 apps all do. That binstub resolves against the app's own
   Gemfile, whose gems Conductor never installs (it deploys the app, it doesn't
   bundle it). So the preferred branch was broken too.

**Fix (shipped in this repo):** `kamal_bin` now runs Conductor's own bundled
Kamal with the Gemfile pinned, since the working directory is the app's checkout:

```
BUNDLE_GEMFILE=/rails/Gemfile bundle exec kamal deploy …
```

Verified in the live container from a foreign working directory under a login
shell — the exact conditions that were failing — returns `2.10.1`. Override with
`CONDUCTOR_GEMFILE` if the app root ever moves. Regression test:
`test/services/kamal_deployer_test.rb` ("invokes Conductor's bundled kamal").

**No shell on the box was needed for the fix** — it's a code change, and it ships
with the next Conductor deploy.

Needs from deploy:
- Once Conductor's own deploy carrying this change is live (check `/version`
  against `origin/main` HEAD), re-fire deploy 13 and report where it gets to.
- If it fails again, capture the exact failing command line from the deployment
  log rather than inferring the cause — the last two guesses (missing binary,
  missing gem) were both wrong in the same way.

Signed: staff-engineer
