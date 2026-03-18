# SSH Key Management Plan

## Goal
Let users manage SSH keys for provisioning and access to VMs.

## Scope
- Store SSH public keys per workspace/user.
- Attach keys during Hetzner provisioning.
- Show key usage per host.

## Non-goals
- Private key storage.

## Milestones
1. SSH key model + CRUD UI.
2. Provisioning flow uses selected keys.
3. Host detail shows installed keys.

## Dependencies
- Workspace and provisioning flows.

## Risks
- Key sprawl without rotation guidance.

## Open Questions
- Allow per-project keys or workspace-level only?
