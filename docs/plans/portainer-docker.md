# VM & Docker Visibility Plan

## Goal
Expose VM state and Docker container details from each host.

## Scope
- Host details (CPU, memory, disk, uptime).
- Docker inventory (containers, images, volumes, networks).
- Basic actions: restart container, view logs.

## Non-goals
- Full container orchestration UI.

## Milestones
1. Agent or Portainer API integration.
2. Host detail page with Docker inventory.
3. Log viewer and restart actions.

## Dependencies
- Portainer agent or custom host agent.

## Risks
- Permissions and secure access to Docker APIs.

## Open Questions
- Portainer API vs custom agent endpoints?
