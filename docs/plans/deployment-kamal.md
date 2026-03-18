# Deployment (Kamal) Plan

## Goal
Generate and run Kamal deployments per environment with minimal manual setup.

## Scope
- Dynamically generate `kamal.yml` per app.
- Manage secrets and env vars.
- Trigger deploys via background jobs.

## Non-goals
- CI/CD system replacement (use GitHub Actions for builds).

## Milestones
1. App model includes repo + image registry reference.
2. Generate Kamal config and validate.
3. Trigger deploy, record status, and surface logs.

## Dependencies
- Container registry and build pipeline.
- SSH access to hosts.

## Risks
- Drift between generated config and live state.
- Secret handling across environments.

## Open Questions
- GitHub Actions vs local build runner?
- How to handle rolling deploys vs blue/green?
