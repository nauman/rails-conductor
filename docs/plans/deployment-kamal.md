# Deployment (Kamal) Plan

## Pillar
Runtime backends

## Status
Stale

## Current Reality

- Conductor already ships a working Docker deploy flow over SSH.
- That flow uses raw Docker commands, not Kamal CLI.
- The current product does not require Kamal to function.
- This plan still describes a Kamal-first world that no longer matches the implemented baseline.

## Goal

Revisit Kamal as an optional runtime backend that adds richer Docker lifecycle features without replacing the existing SSH-driven deploy foundation.

## Scope

- Kamal as a backend adapter, not the only deployment path
- Generated Kamal config per managed app where needed
- Registry-aware deploy flows
- Release tracking and rollback support
- Compatibility with shared visibility in dashboard, logs, and issues

## Non-goals

- Replacing the current Docker deploy flow before a Kamal path is proven
- Building a full CI/CD product
- Making Kamal mandatory for all Docker apps

## Core Workflows

1. Choose Kamal as the backend for an app that benefits from it.
2. Generate or manage backend config safely.
3. Run a Kamal deploy and normalize logs, health, and status into Conductor.
4. Roll back using tracked release state when supported.

## Requirements

1. Treat Kamal as one runtime backend among several.
2. Keep deploy state, health checks, and logs normalized across backends.
3. Define how generated config is stored, validated, and diffed.
4. Support registry credentials and release history before claiming Kamal support is complete.
5. Keep the current raw-Docker path available until Kamal support is production-worthy.

## Dependencies

- `docs/plans/routing-caddy.md`
- registry credential and release-state support
- runtime backend abstraction in deployment code

## Milestones

1. Rewrite this plan around Kamal-as-backend, not Kamal-as-default.
2. Define config storage and validation approach.
3. Add registry-aware deploy path.
4. Add release tracking and rollback.
5. Decide whether Kamal materially improves the current Docker flow.

## Risks

- Generated config can drift from live state.
- Kamal complexity may not justify itself for the current product stage.
- Backend-specific behavior can leak into the common deploy model.

## Open Questions

- GitHub Actions vs local build runner?
- How to handle rolling deploys vs blue/green?
- Which apps should use Kamal instead of the simpler SSH+Docker path?
