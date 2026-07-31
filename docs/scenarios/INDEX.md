# Scenarios

User-driven scenarios that define what Conductor should do. Each scenario captures a real use case with actors, goals, and expected behavior.

## How to Use These Docs

1. Describe your use case naturally
2. AI/developers extract actors, actions, and acceptance criteria
3. Scenarios become the source of truth for feature development

See `AGENTS.md` → "Scenario Workflow" for the full authoring process and doc structure.

## Scenarios

| ID | Name | Primary Actor | Status |
|----|------|---------------|--------|
| SC-001 | [Kamal App Monitoring Dashboard](./sc-001-kamal-monitoring.md) | Indie Developer | Draft |
| SC-002 | [Publish a Route for an App](./sc-002-publish-route.md) | Indie Developer | Draft |
| SC-003 | [Restore a Database Backup](./sc-003-restore-backup.md) | Indie Developer | Draft |
| SC-004 | [Create and Bootstrap a Server](./sc-004-create-server.md) | Indie Developer | Draft |
| SC-005 | [Connect a Domain (DNS + Route)](./sc-005-connect-domain.md) | Indie Developer | Draft |
| SC-006 | [Move an App to Another Server](./sc-006-move-app.md) | Indie Developer | Draft |
| SC-007 | [Detect Drift Across the Fleet](./sc-007-detect-drift.md) | Indie Developer | Draft |
| SC-008 | [Beta Access and Registration Intake](./sc-008-beta-access.md) | Platform Admin | Draft |
| SC-009 | [Three-Tier Org Roles (Owner / Editor / Member)](./sc-009-editor-role.md) | Organization Owner | Draft |
| SC-010 | [Client Access and Managed Billing](./sc-010-client-access-managed-billing.md) | Platform Admin / Client | Draft |

The first seven scenarios cover the core product loops: monitor, publish,
restore, create, connect, move, and detect. SC-008 covers hosted beta intake,
SC-009 the org role model, and SC-010 resource-scoped client access plus managed
backup/server-space billing.
