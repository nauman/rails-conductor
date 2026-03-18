# VM & Docker Visibility Plan

## Pillar
Fleet control

## Status
Partial

## Current Reality

- VM state and basic Docker container visibility already exist through SSH-driven collection.
- The original Portainer/agent framing is outdated for the current product direction.
- The gap is richer container inventory and action support, not basic host visibility.

## Goal

Expose practical VM and Docker state from managed hosts so operators can inspect runtime state without leaving Conductor.

## Scope

- Host details: CPU, memory, disk, uptime
- Docker inventory: containers, images, volumes, networks
- Basic container actions where safe
- Link Docker state back to apps and issues in the fleet model

## Non-goals

- Full container orchestration UI
- Requiring Portainer as a dependency
- Replacing direct SSH access for every debugging task

## Core Workflows

1. Open a host and inspect current Docker container state.
2. See which containers belong to which managed apps.
3. Restart or inspect a container during troubleshooting.
4. Use Docker visibility as part of a larger fleet workflow, not a siloed screen.

## Requirements

1. Support Docker visibility through the current SSH-first model.
2. Treat Portainer as optional, not foundational.
3. Show enough inventory to diagnose app/runtime mismatches.
4. Link container state to the existing app and issue models.
5. Keep container actions narrow and operationally safe.

## Dependencies

- `docs/plans/monitoring-ops.md`
- runtime backend metadata for Docker apps
- log access from `docs/plans/logs-observability.md`

## Milestones

1. Keep current host and container visibility as the baseline.
2. Expand Docker inventory depth where it improves troubleshooting.
3. Link containers to managed apps more explicitly.
4. Add safe restart and inspection actions.

## Risks

- Docker access permissions are sensitive on production hosts.
- Rich inventory can drift from the actual managed-app model.
- Portainer can distract the product from its SSH-first control-plane direction.

## Open Questions

- Should Portainer remain an optional integration or be dropped entirely?
- Which Docker resources matter enough to surface first: containers, images, or volumes?
- What is the safe boundary for container actions inside Conductor?
