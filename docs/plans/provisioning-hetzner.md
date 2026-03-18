# Provisioning (Hetzner) Plan

## Pillar
Provisioning and provider automation

## Status
Deferred

## Current Reality

- Hetzner credentials can be modeled and stored.
- No Hetzner API integration exists.
- Server creation is still manual outside Conductor.
- Bootstrap is SSH-first; there is no agent model in the current vision.

## Goal

Provision Hetzner servers from the control panel and take them from “new VM” to “ready for deploy” using Conductor-managed SSH bootstrap flows.

## Scope

- Hetzner API integration for create/list/delete server workflows
- Region, server type, image, and SSH key selection
- Automatic registration of provisioned servers in Conductor
- SSH bootstrap flow to install Docker, Caddy, PostgreSQL, Redis, and app prerequisites as needed
- Readiness verification after bootstrap

## Non-goals

- Advanced private networking, load balancers, or autoscaling in v1
- Support for every cloud provider in the first pass
- Replacing infrastructure-as-code for advanced users

## Core Workflows

1. Save a Hetzner credential and verify it.
2. Choose region, server type, image, and SSH key.
3. Create the server and wait for a reachable IP.
4. Bootstrap the host over SSH with the right Conductor script chain.
5. Register the server in Conductor and show readiness state.

## Requirements

1. Build a `HetznerClient` for server types, locations, SSH keys, and server lifecycle actions.
2. Support Hetzner SSH key registration from stored keys.
3. Model provisioning state from requested to ready, with failure reasons.
4. Use SSH-based bootstrap rather than an agent dependency.
5. Expose provisioning results to later domain, routing, and deploy workflows.

## Dependencies

- `docs/plans/ssh-keys.md`
- `docs/plans/cloudflare.md`
- `docs/plans/routing-caddy.md`

## Milestones

1. Add credential validation and API client foundation.
2. Implement server type, region, and SSH key selection.
3. Implement VM creation and polling until reachable.
4. Run SSH bootstrap and record readiness state.
5. Connect provisioned hosts to deploy and routing flows.

## Risks

- Provider API rate limits or outages can stall setup flows.
- Bootstrap failures may leave half-configured hosts behind.
- SSH reachability timing can vary based on image and region.

## Open Questions

- Use cloud-init, SSH script, or a hybrid approach for first boot?
- Shared base image vs vanilla Ubuntu?
- Should initial server provisioning include PostgreSQL and Redis by default or by selected stack?
