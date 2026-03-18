# GPT Assistant Plan

## Goal
Provide an AI-assisted ops helper to guide deployments, troubleshoot, and generate configs.

## Scope
- Suggested actions based on errors.
- Generate Kamal configs and Dockerfiles.
- Explain logs and recommended fixes.

## Non-goals
- Autonomous changes without user approval.

## Milestones
1. Prompt templates tied to common tasks.
2. Log and error context packaging.
3. Action suggestions surfaced in UI.

## Dependencies
- Access to logs, configs, and environment metadata.

## Risks
- Hallucinated fixes; must require user confirmation.

## Open Questions
- Where to run inference (API vs local)?
