# Server Bootstrap Plan

## Pillar
Provisioning and provider automation

## Status
Partial

## Current Reality

- Conductor can run provisioning scripts over SSH once a server is known and reachable.
- Hetzner server creation is not automated yet.
- There is no formal plan for the post-creation sequence that turns a raw VM into a usable host.
- This missing sequence is what keeps provider automation from becoming a real end-to-end workflow.

## Goal

Define the end-to-end bootstrap flow that starts after a VM is created and ends when the server is ready for deploy, routing, backups, and ongoing monitoring.

## Why This Plan Exists

`provisioning-hetzner.md` covers VM creation. This plan covers everything after the provider says “server exists.” Without this step, provider automation still leaves the user with manual setup work and unreliable handoff.

## Scope

- Post-create polling until a host is reachable
- SSH-based bootstrap sequence
- Ordered provisioning script execution
- Readiness checks
- Failure handling and partial-state recovery
- Registration of resulting server state inside Conductor

## Non-goals

- Advanced private network topology in the first pass
- Complete OS hardening framework
- Full immutable image pipeline from day one
- Replacing manual debugging for bootstrap failures

## Assumptions

- Conductor already has a valid provider credential and selected SSH key.
- A new server record can be created before bootstrap completes.
- SSH remains the default execution model rather than an installed agent.
- The v1 first-boot method follows the SSH-first decision already made in `provisioning-hetzner.md`.

## Bootstrap Definition

A server is “bootstrapped” when:

1. the host is reachable over SSH
2. the selected bootstrap scripts have completed successfully
3. required baseline services are installed
4. Conductor can run later deploy and health workflows against the host
5. the server is marked ready with clear provenance

## Target Host Profiles

The bootstrap plan should support at least these profiles:

### Docker-oriented host

- Docker available
- Caddy available if needed
- deploy user configured

### Native multi-app host

- Caddy available
- deploy user configured
- Ruby/runtime prerequisites available
- PostgreSQL and Redis available where selected

The profile should be explicit in the provisioning flow, not inferred silently.

## Existing Script Baseline

Conductor already has five built-in scripts that shape the current bootstrap reality:

1. `server-provision`
2. `ruby-install`
3. `app-setup`
4. `app-deploy`
5. `systemd-setup`

### Current mapping

- base host preparation = `server-provision`
- deploy user setup = part of `server-provision`
- runtime package installation for native Ruby = `ruby-install`
- native service setup = `systemd-setup`

`app-setup` and `app-deploy` belong later in app-level deployment, not host bootstrap.

### Important limitation

`server-provision` is currently too monolithic for fully profile-aware bootstrap because it installs multiple concerns together.

This plan should therefore assume:

- v1 may use the existing script baseline pragmatically
- profile-specific bootstrap will eventually require splitting or parameterizing `server-provision`

That is a known implementation constraint, not a reason to pretend the current scripts are already perfectly modular.

## Bootstrap Workflow

### Phase 1: Provisioned but not yet reachable

1. Create server with provider API.
2. Store provider id, selected region, image, and SSH key reference.
3. Poll for assigned IP and provider-ready state.
4. Wait for SSH reachability.

### Phase 2: First access and host preparation

1. Establish SSH connection with selected key and initial user.
2. Validate OS assumptions.
3. Record bootstrap start time and initiating actor.
4. Run the first baseline script or script chain.

### SSH user transition

Bootstrap begins with the provider-default administrative user, typically `root`.

After the deploy user is created and validated:

- Conductor should update the server's operational SSH user to the deploy user
- later deploys, metrics, and routine operations should use the deploy user where appropriate

The root-to-deploy transition is part of bootstrap correctness, not a later cleanup step.

### Phase 3: Ordered script execution

Suggested order:

1. base host preparation
2. deploy user setup
3. runtime package installation
4. Docker or native stack setup
5. Caddy setup where applicable
6. database or cache setup where selected

This order must be profile-aware rather than always-on.

### Phase 4: Readiness verification

1. Confirm expected users, directories, and packages exist.
2. Confirm SSH access works for the intended operational user.
3. Confirm Caddy or Docker presence where required.
4. Confirm Conductor can run a simple follow-up command successfully.
5. Mark the host ready or failed with concrete reason.

### Recommended first-pass verification commands

These checks do not need to be exhaustive, but they should be explicit enough to avoid vague "ready" states.

Baseline examples:

- `id deploy` — deploy user exists
- `caddy version` — Caddy installed
- `systemctl is-active caddy` — Caddy running
- `curl -s http://localhost:2019/config/` — Caddy Admin API responding where Caddy is expected

Docker-oriented host examples:

- `docker --version`

Native host examples:

- `ruby --version`
- `pg_isready` where Postgres is part of the selected stack

The verification set should remain profile-aware rather than forcing every host through every check.

## Streaming and Operator Visibility

Bootstrap progress should stream in real time using the same operational pattern Conductor already uses for provisioning and deploy output.

Minimum operator visibility expectations:

- show current bootstrap phase
- stream command/script output as it runs
- record start time, end time, and failed step
- keep enough output to debug failed runs later

## State Model

Recommended bootstrap states:

- requested
- provisioning
- waiting_for_ip
- waiting_for_ssh
- bootstrapping
- verifying
- ready
- failed

Each failed state should record:

- failed step
- error summary
- last output reference
- whether retry is safe

### Bootstrap state storage

Bootstrap lifecycle should not overload the existing `Server.status` field.

Recommended v1 approach:

- keep runtime health in `Server.status`
- add separate bootstrap lifecycle state for provisioning/bootstrap progress

That keeps operational health and provisioning lifecycle from colliding conceptually.

## Script Orchestration Rules

1. Scripts must remain versioned and identifiable.
2. Bootstrap runs should record which scripts and script versions were used.
3. Different host profiles must select different script chains.
4. A bootstrap rerun should be intentional and safe where possible.

## Idempotency and Retry Stance

Retry behavior depends on script behavior, and the current scripts are not uniformly idempotent.

Recommended v1 stance:

1. make scripts more idempotent where practical
2. also support resume-from-known-step rather than blind rerun

This is not either/or.

Why:

- full blind rerun is unsafe if earlier steps create users, packages, or services non-idempotently
- perfect idempotency across every shell path is unrealistic in the first pass

So the bootstrap system should track completed phases and prefer resuming from the failed step while improving script idempotency over time.

## Failure Handling

### Provider-side failure

- server never gets an IP
- provider marks instance unhealthy

Conductor response:
- stop before SSH attempts
- mark provisioning failure

### SSH reachability failure

- wrong key
- firewall issue
- instance not ready

Conductor response:
- retry within a bounded window
- record failure stage explicitly

### Script failure

- package install fails
- service setup fails
- permissions mismatch

Conductor response:
- stop the chain
- preserve logs
- mark host as partially bootstrapped

## Timeout Budget

Bootstrap should have both step-level timeout expectations and an overall timeout budget.

Recommended first-pass total budget:

- 20 minutes maximum bootstrap duration before the run is marked failed

This prevents the system from leaving a host indefinitely stuck in a bootstrap state.

## Recovery and Retry Rules

1. Retry must start from a known bootstrap state, not blindly rerun everything.
2. Operators must be able to see whether retry is safe.
3. Hosts left in partial state should be clearly marked.
4. Conductor should prefer replayable script boundaries over one giant shell script.

## Recurring Operations Enrollment

Once a host is marked ready, it should automatically become eligible for ongoing monitoring and freshness loops.

That means:

- metrics refresh should see it
- later runtime-specific status checks should see it
- no separate manual enrollment step should be required after bootstrap success

## Data Model Implications

Likely additions or clarifications:

- bootstrap status
- bootstrap profile
- last bootstrap run id
- last bootstrap error
- bootstrap completed at
- provider server id and metadata already linked to host record

Recommended clarification:

- bootstrap lifecycle state should be separate from runtime health state

## Dependencies

- `docs/plans/provisioning-hetzner.md`
- `docs/plans/ssh-keys.md`
- `docs/plans/cloudflare.md`
- provisioning script system already in the app

## Milestones

1. Define host profiles and bootstrap state model.
2. Map the current built-in scripts to bootstrap phases and identify where script splitting or parameterization is needed.
3. Define script chains per profile.
4. Define post-create polling and SSH reachability flow.
5. Add readiness verification checklist and root-to-deploy user transition.
6. Integrate bootstrap result into provider automation and later deploy flows.

## Acceptance Checks

- A newly created server can move to a visible ready state without manual shell steps.
- Bootstrap failures show the failed step clearly.
- Retry does not hide partial-state risk.
- Ready hosts can immediately participate in later deploy or routing flows.

## Open Questions

### First-boot model

Use SSH-driven bootstrap in v1, following the provisioning decision already made.

### Baseline vs profile-specific packages

Prefer profile-specific installation. The current script baseline may need decomposition or parameterization to support that cleanly.

### Postgres and Redis selection

Select them explicitly during bootstrap/profile choice rather than inferring them silently from workload.

### Verification depth

Minimum verification is enough for later deploy and monitoring to function:

- SSH works for the intended operational user
- profile-required services are present
- Caddy Admin API responds where Caddy is part of the profile
