# Workspaces Plan

## Goal
Give each user a workspace containing repos, environments, domains, and hosts.

## Scope
- Core models: Workspace, Project, Environment, Host, App, Credential.
- UI to create/edit workspaces and view linked assets.

## Non-goals
- Team permissions and roles beyond owner/admin.
- Billing integration.

## Milestones
1. Data model + migrations.
2. Basic CRUD UI for workspaces and projects.
3. Environment views that connect hosts, domains, and deployments.

## Dependencies
- Auth system and user accounts.
- Credential storage approach.

## Risks
- Schema churn as provisioning and deployment evolve.

## Open Questions
- Do we treat personal workspace as default for each user?
- How to model multiple repos per project?
