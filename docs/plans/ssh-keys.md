# SSH Key Management Plan

## Pillar
Provider automation

## Status
Partial

## Current Reality

- SSH key records and CRUD already exist.
- Keys are used for server access inside Conductor.
- Provider registration state is not tracked yet.
- The remaining gap is provider-facing key lifecycle, especially Hetzner registration and setup flows.

## Shipped Baseline

Current SSH key support already includes:

- encrypted private key storage
- encrypted passphrase storage
- automatic fingerprint, public key, and key-type extraction on save
- server association through the existing `Server -> SshKey` relationship
- masked private-key display helpers
- support for common SSH key formats through `Net::SSH::KeyFactory`

This plan does not need to rebuild key CRUD. It needs to extend the model from local storage into provider-facing registration and safer operational visibility.

## Goal

Manage SSH keys as operational credentials for provisioning, bootstrap, and ongoing server access.

## Scope

- SSH key CRUD and usage tracking
- Provider-facing key registration for Hetzner
- Key selection during provisioning
- Visibility into which servers and flows depend on which keys
- Rotation and replacement guidance
- Security expectations for handling private keys inside Conductor

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
2. Track key usage across servers, with deeper action-level usage deferred.
3. Support provider registration where required, starting with Hetzner.
4. Make it clear whether a key is local-only, provider-registered, or both.
5. Guarantee that a provider-registrable public key is available before Hetzner registration is attempted.
6. Surface risky situations such as orphaned servers or unknown key ownership.

## Hetzner Registration Requirement

Hetzner registration requires a valid public key in OpenSSH format.

That means this plan must ensure:

- Conductor can reliably derive and persist a valid public key from the stored private key
- validation fails clearly if the public key cannot be derived
- Hetzner registration never proceeds with a missing or malformed public key

If the current stored `public_key` format is not guaranteed to be OpenSSH-compatible, the model or registration layer must normalize it before API submission.

## Usage Tracking Scope

For v1, usage tracking should mean:

- which servers reference a given SSH key
- whether the key is the default provisioning key
- whether the key has been registered with Hetzner

Detailed action history such as “last bootstrap used this key” or “last script run used this key” should come later.

## Provider Registration State

Conductor needs a way to distinguish local key storage from provider registration state.

For v1, this can be simple and Hetzner-specific:

- `hetzner_key_id`
- `hetzner_registered_at`
- registration status or failure summary

A provider-registration join model may be cleaner later if more providers need SSH key registration, but the first pass should optimize for the actual Hetzner workflow rather than future abstraction.

## Rotation Stance

Fully automated rotation is too risky for the first pass.

For v1, rotation should be guided manual:

1. Show all servers that depend on the current key.
2. Register the replacement key with Hetzner.
3. Tell the operator which hosts must receive the new public key.
4. Update Conductor associations once access is confirmed.
5. Only then remove or deregister the old key.

This gives operators a clear checklist without pretending Conductor can safely rotate every host automatically.

## Key Generation Stance

Import-only for v1.

Operators should generate key pairs outside Conductor and import them. In-product key generation is helpful later, but it is not required to support the provisioning flow.

## Security Considerations

- Private keys and passphrases remain encrypted at rest.
- Private keys must never appear in logs, error traces, or API responses.
- Masked display helpers should remain the only default UI representation of secret key material.
- Export or download of stored private keys should not be added casually.

## Dependencies

- `docs/plans/provisioning-hetzner.md`
- server bootstrap and provisioning flows

## Milestones

1. Keep current CRUD and server association as the baseline.
2. Add provider registration state and Hetzner key registration.
3. Add usage views and replacement guidance.
4. Add guided manual rotation workflow for affected servers.

## Risks

- Key sprawl without clear ownership or rotation policy.
- Provider registration can drift from locally stored key state.
- Rotation can break bootstrap and access if dependencies are not tracked well.

## Decisions

- Keys are instance-level for v1 because no workspace model exists yet.
- The minimum safe rotation workflow is guided manual, not fully automated.
- Conductor should support one default provisioning key plus per-server overrides.
