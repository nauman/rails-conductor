# SC-008: Beta Access and Registration Intake

## User Story (Raw)

> "if someone registers at moment can they conductor ? like will this effect our performance, i dont want to gate or charge atm but what should we do, do beta access waitlist let them through?"

---

## Actors

| Actor | Description |
|-------|-------------|
| **Visitor** | Someone who finds the hosted Conductor instance and wants to try it. |
| **Beta User** | Approved visitor using Conductor for a real fleet during the free beta. |
| **Platform Admin** | Conductor operator who reviews requests, creates users, and watches capacity. |
| **Conductor** | Hosted Rails app that keeps sign-in invite-only and scopes data by organization. |
| **Background Workers** | Solid Queue workers running deploys, scripts, log fetches, backups, and health checks. |

---

## Goals

1. Let people express interest without creating open self-serve signup.
2. Admit approved beta users for free while billing is not ready.
3. Protect app performance and worker capacity from unbounded usage.
4. Preserve no-user-enumeration behavior on sign-in.
5. Keep a clear path from waitlist request to approved organization access.

---

## Scenario Flow

### Scenario 8.1: Visitor Requests Beta Access

**Preconditions:**
- Production has already bootstrapped at least one platform admin.
- Public sign-in remains invite-only; unknown emails do not create users.
- The landing page can point visitors to a beta access request form or external waitlist.

**Flow:**
1. Visitor opens the public Conductor landing page.
2. Visitor chooses "Request beta access".
3. Visitor submits email, intended use case, expected number of servers/apps, and preferred deploy style.
4. System records the request as `requested`.
5. System shows a neutral confirmation that avoids revealing whether the email already has an account.
6. Platform admin reviews the request before granting access.

**Acceptance Criteria:**
- [ ] No `User`, `Organization`, API token, server, app, or backup is created from the request alone.
- [ ] Unknown emails submitted to sign-in still do not receive magic links.
- [ ] Request submission is rate-limited and validates email format.
- [ ] Request data contains no secrets, server passwords, SSH keys, or cloud tokens.
- [ ] Admin can see expected fleet size before approval.

---

### Scenario 8.2: Admin Approves a Free Beta User

**Preconditions:**
- Visitor has a reviewed beta request.
- Platform admin has decided the expected usage fits current capacity.

**Flow:**
1. Platform admin marks the request `approved`.
2. Platform admin creates a user or sends an invitation.
3. Beta User signs in with a magic link.
4. Conductor creates or assigns the user's organization.
5. Beta User completes onboarding and registers their first server/app.
6. Admin monitors usage, background jobs, MCP calls, and error rate.

**Acceptance Criteria:**
- [ ] Approved beta access is free and does not require billing setup.
- [ ] Each beta user operates inside an organization-scoped workspace.
- [ ] Per-user/API/MCP tokens are bound to the active organization.
- [ ] Admin can disable access by removing the user, membership, or token.
- [ ] Admin can identify which organization triggered expensive jobs.

---

### Scenario 8.3: Usage Exceeds Beta Capacity

**Preconditions:**
- One or more beta users are active.
- Background workers or infrastructure integrations are under load.

**Flow:**
1. Conductor detects high job latency, repeated failures, excessive log polling, or large backup volume.
2. Admin pauses new approvals.
3. Admin contacts affected beta users or temporarily disables risky tokens.
4. Admin records the limit that would have prevented the issue.
5. Product backlog captures a guardrail before reopening beta approvals.

**Acceptance Criteria:**
- [ ] Existing users are not silently charged or blocked without explanation.
- [ ] Admin can stop issuing new beta access without disabling sign-in for existing users.
- [ ] Failure modes are visible in admin views, logs, or worker dashboards.
- [ ] New limits are documented before the next beta batch is admitted.

---

## Data Model Implications

```text
BetaAccessRequest
├── email
├── name
├── use_case
├── expected_servers
├── expected_apps
├── deploy_style
├── status (requested | approved | rejected | paused)
├── reviewed_by_id
├── reviewed_at
└── notes
```

Existing models remain the access boundary:

```text
User ── Membership ── Organization
Organization ── Servers / Apps / Backups / ApiTokens
```

Optional guardrail fields can live on `Organization` until billing exists:

```text
beta_status
server_limit
app_limit
backup_limit_gb
concurrent_job_limit
```

---

## Technical Notes

- Current auth is invite-only after first-user bootstrap: unknown sign-in emails do not create users.
- Production must not be left with an empty database on a public hostname, because the first sign-in bootstraps the platform admin.
- Team invitations and public beta intake are different flows. Invitations add a person to an existing org; beta intake should let the platform admin approve a new external user deliberately.
- Performance risk comes mainly from worker-backed actions: deploys, scripts, log tails, backups, and health checks. Passive sign-in and dashboard reads are lower risk.
- Start with manual approval plus soft limits. Add billing only after usage patterns and cost drivers are known.

---

## Open Questions

1. Should beta approval create a personal organization automatically, or should admins create a named organization first?
2. What is the first beta batch size: 5, 10, or 20 organizations?
3. What soft caps should apply before billing exists?
4. Should waitlist storage live in Conductor or an external form until the flow proves useful?
5. What mechanism should disable first-user bootstrap after production setup?

---

## Priority

**High** - Needed before promoting the hosted instance beyond trusted manual invites.
