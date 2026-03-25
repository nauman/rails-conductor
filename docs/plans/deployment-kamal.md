# Deployment (Kamal) Plan

## Pillar
Runtime backends

## Status
Stale

## Current Reality

- Conductor already ships a working Docker deploy flow over SSH.
- That flow uses raw Docker commands, not Kamal CLI.
- The current Docker path already covers clone or pull, image build, container replace, environment injection, health check, cleanup, deployment status tracking, and streamed logs.
- The current product does not require Kamal to function.
- This plan should be treated as a decision and assessment document until higher-priority routing, provider, and backup gaps are closed.

## Goal

Revisit Kamal as an optional runtime backend that adds meaningful Docker lifecycle value without replacing the existing SSH-driven deploy foundation unless it clearly improves the product.

## Why This Plan Exists

The product already has a functioning Docker deployer. Kamal is only worth integrating if it provides concrete operational value that Conductor does not already have and if that value fits the rest of the architecture, especially Caddy-based routing and the SSH-first control model.

## Scope

- Kamal as a backend adapter, not the only deployment path
- Assessment of where Kamal adds value over the current Docker flow
- Execution model for running Kamal from the Conductor host
- Compatibility with shared visibility in dashboard, logs, and issues
- Decision criteria for whether Kamal should move from assessment into implementation

## Non-goals

- Replacing the current Docker deploy flow before a Kamal path is proven
- Building a full CI/CD product
- Making Kamal mandatory for all Docker apps
- Adopting `kamal-proxy` as the default routing layer while Caddy is the product routing standard
- Generating `deploy.yml` for every app before Kamal's value is proven

## Core Workflows

1. Assess whether a specific app benefits from Kamal over the existing SSH plus Docker path.
2. Reuse an app's existing Kamal config where present rather than generating config by default.
3. Run a Kamal deploy from the Conductor host and normalize logs, health, and status into Conductor.
4. Decide whether registry-based releases and rollback support justify a maintained Kamal backend.

## Shipped Docker Baseline

Current Docker deploy behavior already includes:

- repo clone or pull on the target server
- local image build on the target server
- container stop and replace
- environment variable injection via Docker flags
- configurable health check path with retries
- deployment state tracking in Conductor
- ActionCable log streaming during deploy

This baseline matters because Kamal should be measured against an existing working deployer, not against an empty slot.

## Kamal Value Assessment

| Kamal Feature | Value Over Current Flow | Cost or Conflict |
| --- | --- | --- |
| Registry push and pull | Avoids building on production hosts and enables tagged image releases | Medium; needs registry credentials and image lifecycle handling |
| Rolling deploys | Improves multi-instance deploy safety | High; only matters once multi-instance deploy orchestration exists |
| Rollback | Provides structured release reversion | Medium; requires release tracking and image history |
| Accessories | Can manage sidecar containers | Low to medium; less aligned with Conductor's native Postgres direction |
| `kamal-proxy` | Built-in deploy proxy | High conflict; overlaps with Caddy routing model |
| Secrets in deploy config | Centralized deploy config input | Low value; overlaps with Conductor credential and env-variable handling |

The most likely meaningful Kamal value for Conductor is registry-aware deploys plus release rollback. The least aligned parts are `kamal-proxy` and features that duplicate existing Conductor credential handling.

## Architectural Decision: Caddy vs kamal-proxy

For v1, Conductor should assume Caddy remains the routing and edge layer.

That means:

- Kamal must be evaluated without taking ownership of edge routing
- `kamal-proxy` should not become the default proxy model for Conductor-managed apps
- Kamal is a better fit for registry-based container lifecycle than for request routing

If Kamal cannot be used cleanly without undermining the Caddy routing model, that is a valid reason not to integrate it.

## Execution Model

Kamal should not be run over a second SSH hop from the target server. For v1, if Kamal is ever implemented, it should run on the Conductor host and SSH directly into the target servers using Conductor-managed SSH credentials.

That implies:

- Kamal CLI must be available on the Conductor host
- Conductor must materialize the right SSH credential context for the target
- deployment output must still be captured and normalized into the existing Deployment model

This is materially different from the current raw Docker deployer, which executes Docker commands directly over `SshConnection`.

## Config Strategy

For the first Kamal-compatible pass, Conductor should prefer an app's existing `config/deploy.yml` if one already exists.

Conductor should not start by generating Kamal config for every app. Config generation, validation, and diffing are only worth adding after Kamal proves useful enough to support as a maintained backend.

## Backend Abstraction

If Kamal is implemented later, it should live behind a dedicated `KamalDeployer` that writes to the same Deployment model and normalizes health, logs, and failure states into the same operator-facing surfaces as the current Docker and native deployers.

The current simple branch-based backend selection is acceptable for now. A more elaborate registry or strategy layer is only necessary if the number of runtime backends grows further.

## Requirements

1. Treat Kamal as one runtime backend among several.
2. Keep deploy state, health checks, and logs normalized across backends.
3. Define whether Kamal can operate cleanly alongside Caddy without `kamal-proxy` becoming a routing conflict.
4. Run Kamal from the Conductor host, not by nesting SSH from target servers.
5. Support registry credentials and release history before claiming Kamal support is complete.
6. Keep the current raw-Docker path available until Kamal support is production-worthy.

## Dependencies

- `docs/plans/routing-caddy.md`
- `docs/plans/logs-observability.md`
- registry credential and release-state support
- runtime backend abstraction in deployment code

## Milestones

1. Capture the shipped Docker deploy baseline and compare it against Kamal feature value.
2. Decide whether Kamal can coexist with Caddy without adopting `kamal-proxy`.
3. Decide whether running Kamal from the Conductor host is operationally acceptable.
4. Revisit config ownership, preferring existing `deploy.yml` before generated config.
5. Only if the decisions above are positive, design registry-aware deploy path and release tracking.
6. Decide whether Kamal materially improves the current Docker flow enough to justify implementation.

## Risks

- Generated config can drift from live state.
- Kamal complexity may not justify itself for the current product stage.
- Backend-specific behavior can leak into the common deploy model.
- `kamal-proxy` may conflict structurally with the Caddy routing model.
- Running Kamal locally on the Conductor host may create credential-handling complexity that outweighs the benefit.

## Decisions

- If Kamal is evaluated, it should run locally on the Conductor host, not via GitHub Actions.
- Rolling and blue-green deploy behavior are deferred until Kamal proves useful enough to adopt.
- The best first Kamal candidates are apps that already have a `deploy.yml` and specifically want registry-based releases.
- This plan remains assessment-first until higher-priority routing, provider automation, and backup recovery work are further along.
