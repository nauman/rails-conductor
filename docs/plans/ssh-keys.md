# SSH Key Management Plan

## Pillar
Provisioning and provider automation

## Status
Partial

## Current Reality

- SSH key records and CRUD already exist.
- Keys are used for server access inside Conductor.
- The remaining gap is provider-facing key lifecycle, especially Hetzner registration and setup flows.

## Goal

Manage SSH keys as operational credentials for provisioning, bootstrap, and ongoing server access.

## Scope

- SSH key CRUD and usage tracking
- Provider-facing key registration for Hetzner
- Key selection during provisioning
- Visibility into which servers and flows depend on which keys
- Rotation and replacement guidance

## Non-goals

- General-purpose secrets vault beyond Conductor’s SSH needs
- Supporting every provider’s key model in the first pass
- Turning SSH key management into a standalone product

## Core Workflows

1. Save an SSH key and understand where it is used.
2. Register that key with Hetzner during provisioning.
3. Select the right key for a new server bootstrap flow.
4. Replace or rotate a key without losing track of affected hosts.

## Requirements

1. Keep SSH keys first-class in server provisioning and server access flows.
2. Track key usage across servers and provisioning actions.
3. Support provider registration where required, starting with Hetzner.
4. Make it clear whether a key is local-only, provider-registered, or both.
5. Surface risky situations such as orphaned servers or unknown key ownership.

## Dependencies

- `docs/plans/provisioning-hetzner.md`
- server bootstrap and provisioning flows

## Milestones

1. Keep current CRUD and server association as the baseline.
2. Add provider registration state and Hetzner key registration.
3. Add usage views and replacement guidance.
4. Add rotation workflow for affected servers.

## Risks

- Key sprawl without clear ownership or rotation policy.
- Provider registration can drift from locally stored key state.
- Rotation can break bootstrap and access if dependencies are not tracked well.

## Open Questions

- Allow per-project keys or workspace-level only?
- What is the minimum safe rotation workflow for active servers?
- Should Conductor support one default provisioning key plus per-server overrides?
