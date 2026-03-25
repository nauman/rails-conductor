# VM & Docker Visibility Plan

## Pillar
Fleet control

## Status
Deferred

## Current Reality

- VM state and basic Docker container visibility already exist through SSH-driven collection.
- Container status sync, container logs, and restart actions already exist for managed apps.
- The original Portainer/agent framing is outdated for the current product direction.
- The remaining unique gap is Docker hygiene visibility, not core container operations.

## Goal

Document the remaining Docker-specific visibility work honestly: managed-container operations already exist, while broader Docker hygiene and unmanaged-container visibility are deferred until higher-priority control-plane work is further along.

## Shipped Baseline

Current Docker-related visibility already includes:

- server metrics over SSH
- container status sync for managed apps
- container status fields on app records
- managed container restart flow
- managed container logs through app log retrieval

This means Conductor already covers the operational Docker surface required for the core app lifecycle. What is left is convenience and hygiene, not a missing foundation.

## Scope

- Document the remaining Docker hygiene opportunities
- Define how unmanaged containers would be surfaced if this work is revived
- Clarify safe boundaries for Docker actions inside Conductor

## Non-goals

- Full container orchestration UI
- Requiring Portainer as a dependency
- Replacing direct SSH access for every debugging task
- Building a full Docker inventory explorer for images, volumes, and networks in v1
- Destructive cleanup flows for unmanaged containers, images, or volumes
- Maintaining a Portainer integration path

## Core Workflows

1. Understand which managed containers are healthy and attached to Conductor apps.
2. Optionally identify unmanaged containers on a host as hygiene or drift signals.
3. Restart or inspect managed containers during troubleshooting.
4. Use Docker visibility as part of a larger fleet workflow, not as a standalone container UI.

## Requirements

1. Support Docker visibility through the current SSH-first model.
2. Drop Portainer as a product integration concern.
3. Treat existing managed-container visibility as the baseline, not as missing work.
4. If broader Docker inventory is revisited, prioritize unmanaged-container detection and image hygiene before volumes or networks.
5. Link Docker state to the existing app and issue models.
6. Keep container actions narrow and operationally safe.

## Remaining Useful Scope

If this work is revived later, the most useful additions are:

- showing containers on a host that are not managed by Conductor
- flagging unmanaged containers as hygiene or drift signals
- surfacing image inventory and possibly dangling image cleanup candidates

Volumes and networks are lower-priority and should stay deferred unless a concrete operator need emerges.

## Safe Action Boundary

Safe actions for Conductor:

- inspect managed containers
- view managed container logs
- restart managed containers

Deferred or unsafe actions:

- stopping unmanaged containers
- removing containers
- deleting images
- pruning volumes or networks
- broad Docker cleanup commands

Conductor should not present destructive Docker actions casually, especially for resources it did not create.

## Dependencies

- `docs/plans/monitoring-ops.md`
- log access from `docs/plans/logs-observability.md`
- recurring freshness from `docs/plans/recurring-ops-schedule.md`

## Milestones

1. Treat current managed-container visibility as sufficient for core Conductor workflows.
2. Defer Portainer entirely.
3. If revisited, add unmanaged-container visibility first.
4. If revisited after that, consider image hygiene visibility.

## Risks

- Docker access permissions are sensitive on production hosts.
- Rich inventory can drift from the actual managed-app model.
- A deeper Docker UI can distract the product from routing, providers, backups, and maintenance.
- Unmanaged-container visibility can create pressure to add destructive controls that Conductor should avoid.

## Decisions

- Portainer is dropped as a Conductor integration concern.
- If Docker inventory expands later, unmanaged containers and images come before volumes or networks.
- The safe v1 boundary is inspect, logs, and restart for managed containers only.
