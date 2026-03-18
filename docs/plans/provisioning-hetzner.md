# Provisioning (Hetzner) Plan

## Goal
Provision VMs from user-provided Hetzner API keys and bootstrap them for Docker + Caddy + Agent.

## Scope
- Hetzner API integration (create/list/delete servers).
- Bootstrap script to install Docker, Caddy, and agent.
- Host registration in Conductor.

## Non-goals
- Advanced networking (VPC, private networks) in v1.
- Autoscaling.

## Milestones
1. Store Hetzner credentials per workspace.
2. Create VM flow with region/size selection.
3. Bootstrap and verify agent heartbeat.
4. Register VM in Portainer (if used).

## Dependencies
- Secure credential storage.
- Agent or SSH bootstrap mechanism.

## Risks
- Provider API rate limits.
- Provisioning failures due to network or image mismatch.

## Open Questions
- Use cloud-init vs SSH script?
- Shared base image vs vanilla Ubuntu?
