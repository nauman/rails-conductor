# SC-009: Three-Tier Org Roles (Owner / Editor / Member)

## User Story (Raw)

> our member area doesn't let [us] manage users and [a teammate] is member but
> [their] token for mcp is not full deploy scope why is that?
>
> owner no why would he be? i think 3 levels, owner, editor and member or
> something where he cant just destroy everything

*(Names and org genericized — this repo is public.)*

## Context: Why Today Fails

Permissions are a single binary predicate, `OperatorPolicy.operator?(user, org)`
(`app/models/operator_policy.rb:11`), true only for an org **owner** or a
platform **admin**. It is called from every surface — 13 controllers via the
`OperatorOnly` concern, `ToolRegistry` (MCP), `Api::BaseController`,
`McpTokensController`, and secret-reveal in views.

Two consequences the user hit:

1. **No role management.** `resources :members, only: [:index, :destroy]`
   (`config/routes.rb:93`). A role is set once, at invite time, and can never be
   changed. There is no `MembersController#update`.
2. **A member's MCP token is silently downgraded.** `McpTokensController#create`
   coerces `scope = "read"` for any non-operator (`app/controllers/mcp_tokens_controller.rb:15`),
   while the form still offers "deploy (full)" unconditionally
   (`app/views/mcp_tokens/index.html.erb:28`). The member picks deploy, receives
   read, and is told nothing.

The only way to let a teammate deploy is to make them an owner — which also
hands them member management and every destructive operation. That is the gap
this scenario closes.

## Actors

| Actor | Description |
|-------|-------------|
| Owner | Full control: everything an editor can do, plus destroy, scripts, stored credentials, and member management. |
| Editor | Trusted operator. Deploys and runs day-to-day infra, but cannot delete resources, run arbitrary commands, or read stored credentials. |
| Member | Read-only. Views apps, deployments, and status. No secrets, no mutations. |
| Platform Admin | `User#admin?` — superuser across all orgs. Unchanged by this scenario. |
| MCP Agent | Claude/Cursor/Codex acting with a user's token; inherits exactly that user's role. |

## Goals

1. Let an owner grant deploy access without granting the org.
2. Keep destructive and credential-bearing operations owner-only.
3. Make the token scope a consequence of role, and never silently downgrade.
4. Enforce one capability model identically across web, API, and MCP.

## Capability Matrix

Decided with the user, then corrected by a codebase audit (2026-07-31). Two
original entries did not survive contact with the code:

- **Backup restore** was listed as an editor capability. There is no restore
  surface — routes expose backup CRUD and `run` only. Removed rather than
  promised.
- **Database pulls** were listed as editor-safe. The pull path interpolates an
  unvalidated env-var name into a remote shell command and drops a database by
  free-text name (`docs/dev/SECURITY-BACKLOG.md`, SB-001). Owner-only until that
  is fixed.

"Full visibility" was chosen for secrets: an editor sees DB URLs and webhook
secrets like an owner, so `current_operator?` in views stays a single check that
now includes editors. Note this does **not** reveal secret env *values* — those
are masked unconditionally, for owners too.

| Capability | Member | Editor | Owner |
|---|:--:|:--:|:--:|
| View apps, servers, deployments, status | ✅ | ✅ | ✅ |
| Deploy, rollback, cancel a deployment | ❌ | ✅ | ✅ |
| Create/update apps, servers, databases, cron jobs | ❌ | ✅ | ✅ |
| Read/write env variables; see DB URLs + webhook secrets | ❌ | ✅ | ✅ |
| Database pulls | ❌ | ❌ | ✅ |
| Mint a `deploy`-scoped MCP token | ❌ | ✅ | ✅ |
| **Destroy** apps, servers, DB clusters; retire/decommission | ❌ | ❌ | ✅ |
| **Run arbitrary commands** — Scripts, `conductor_app` `runner`, cron | ❌ | ❌ | ✅ |
| **Repoint an app** at a different repository | ❌ | ❌ | ✅ |
| Seed production on next deploy | ❌ | ❌ | ✅ |
| **Stored credentials & SSH keys** (read or write) | ❌ | ❌ | ✅ |
| Invite, remove, and change member roles | ❌ | ❌ | ✅ |
| Transfer an app to another org | ❌ | ❌ | ✅ |

**Rationale for the three owner-only bands.** Destroy is the literal "can't
destroy everything" ask. Script execution and `runner` accept arbitrary
Ruby/shell against production, so an editor holding either is unrestricted in
practice and the role would be decorative. Credentials and SSH keys are the keys
to the whole fleet, not one app — and those controllers already gate GET too
(`operator_only_all_actions!`), because a read renders a decrypted secret.

## Scenario Flow

### Scenario 9.1: Owner promotes a member to editor

**Preconditions:** Owner signed in; the teammate is an existing member.

**Flow:**
1. Owner opens `/members`.
2. Each row shows a role control (Member / Editor / Owner) instead of a static badge.
3. Owner switches the teammate to Editor and submits.
4. `MembersController#update` verifies the actor is an owner and persists the role.
5. The list re-renders with the new badge and a confirmation notice.

**Acceptance Criteria:**
- [ ] A non-owner sees badges, never the role control, and `PATCH /members/:id` is rejected for them.
- [ ] An owner cannot demote themselves if they are the last owner (org must always retain one).
- [ ] An owner cannot change their own role in the same request that would orphan the org.
- [ ] Role changes take effect on the teammate's next request without re-login.

### Scenario 9.2: Editor mints a deploy token and ships

**Preconditions:** Teammate is now an editor.

**Flow:**
1. Editor opens `/mcp-tokens` and selects scope "deploy (full)".
2. `McpTokensController#create` no longer coerces to `read` — the editor is an operator.
3. Editor connects the agent and runs `conductor_app` `action: "deploy"`.
4. `ToolRegistry` authorizes: not read-only, actor is an operator, action is not owner-only.
5. Deploy runs and is attributed to the editor.

**Acceptance Criteria:**
- [ ] An editor's `deploy` token authenticates and executes mutating tools.
- [ ] A plain member selecting "deploy" gets a `read` token **and** a visible explanation — no silent downgrade.
- [ ] The scope select offers only options the current user may actually mint.

### Scenario 9.3: Editor is stopped at the owner-only band

**Preconditions:** Editor signed in with a deploy token.

**Flow:**
1. Editor attempts to delete an app (web `DELETE`, or MCP `conductor_app` `action: "retire"`).
2. The capability check fails on `:destroy`.
3. Web redirects with "This action requires an organization owner"; MCP returns a
   legible `Result.fail` naming the missing capability.

**Acceptance Criteria:**
- [ ] Editor is denied: app/server/database destroy, `retire`, `transfer`, `runner`, script runs, credentials, SSH keys.
- [ ] Denials are identical in wording and outcome across web, API, and MCP.
- [ ] An editor's denial is recorded the same way an unauthorized member's is.

## Data Model Implications

- `Membership#role` enum gains `editor`. **Add it as `2`** — `{ member: 0, owner: 1, editor: 2 }` — so existing rows keep their integers. Ordering is semantic in the UI, not in the enum.
- `Invitation#role` must accept `editor`; the invite form gains the option.
- No new tables. No `ApiToken` change: scope stays `deploy`/`read` and remains a *ceiling*, with the role checked at execution time — a stale deploy token held by a demoted user is inert.

## Technical Notes

The refactor is one predicate becoming two:

- `OperatorPolicy.operator?(user, org)` — keep the name and every call site; widen to `owner || editor || admin`. All 13 `OperatorOnly` controllers, the API, and `current_operator?` inherit editor access for free.
- `OperatorPolicy.can?(user, org, capability)` — new, for the owner-only bands (`:destroy`, `:execute`, `:credentials`, `:manage_members`, `:repository`).

**Threat model (decided).** An editor is a *trusted code deployer*: deploying
ships code, so "an editor cannot execute arbitrary code" is a statement about
**ad-hoc** execution — scripts, one-off runners, raw cron, seed toggles — not
about deploys. Repointing an existing app at a different repository is a change
of trust rather than config, so it is owner-only (`:repository`); branch stays
editable, because shipping a hotfix branch is the day-to-day work the role
exists for.

Surfaces needing the new check:

1. **`OperatorOnly`** — add an `owner_only_actions :destroy, ...` macro alongside the existing `operator_only_all_actions!`.
2. **`ScriptsController`, `CredentialsController`, `SshKeysController`** — move from operator-gated to owner-gated (all actions).
3. **`ToolRegistry`** — the real wrinkle. Tools are flat `action` enums (`EnumDispatch`), so `retire`, `transfer`, and `runner` are *actions inside* `conductor_app`, not separate tools. Gating must move from a tool-name list to a `TOOL => [owner_only_actions]` map checked after dispatch resolves the action. `READ_ONLY_TOOLS` has the same shape problem and should be revisited in the same pass.
4. **`Script#editable_by?`** (`app/models/script.rb:24`) — swap `operator?` for `can?(:execute)`. Note this guards *editing* only; execution has three further entry points that each need `:execute` in their own right — `Api::V1::ScriptsController#run`, `ServersController#provision`, and MCP `run_script`.
5. **`McpTokensController`** — keep the coercion as defence-in-depth, but render only mintable options and flash when a downgrade occurs.
6. **`MembersController#update`** + route + role control in `app/views/members/index.html.erb`.

Tests first, per house style: the boundary cases are the last-owner guard, an
editor hitting each owner-only band on all three surfaces, and a demoted user's
existing deploy token going inert.

## Open Questions

1. Should an editor be able to invite **members** (not editors/owners)? Currently owner-only; a small delegation might reduce owner toil.
2. Should `conductor_app` `runner` split read-only Rails tasks (`db:migrate:status`) from arbitrary `ruby`? The former is diagnostic and arguably editor-safe.
3. Does `deploy` itself deserve a hold for editors on production-flagged apps, or is role sufficient?
4. Should role changes be audited (who promoted whom, when)? No audit surface exists for membership today.

## Priority

**High.** Blocks the immediate need — giving a teammate deploy access without
making them an owner — and removes a silent, unexplained token downgrade that
reads as a bug to every new user.
