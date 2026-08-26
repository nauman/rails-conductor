# Root is a registration-only credential

**Date:** 2026-08-26
**Trigger:** Conductor gained a new privileged op (`reclaim_swap`). Its wrapper was
missing on every existing box, and the operator was told to SSH in as root and
paste a setup block. That was wrong: the deploy user could have installed it.

## What the rule already said, and why it did not stop this

`CLAUDE.md` said root is for "provisioning, hardening, OS updates, and installing
packages". Installing a root-owned wrapper script *is* provisioning by any
reasonable reading — so the rule was satisfied and the mistake still happened.

A rule that requires classifying the work fails whenever the work is genuinely
classifiable both ways. The fix is a line that needs no judgement:

> **Root is permitted only while no deploy user with sudo exists yet.**
> That is registration and hardening. Nothing else, ever.

Once `HardenServer` has run, `/etc/sudoers.d/90-deploy` grants
`deploy ALL=(ALL) NOPASSWD:ALL`. There is no privileged operation on that box the
deploy user cannot perform. So after registration there is never an honest reason
to ask for root — only an un-investigated one.

## The specific trap

`ServerSudo.probe` returning `:no_grant` reads like "this box needs root". It does
not. It means the **scoped** sudoers file (`/etc/sudoers.d/conductor`) is missing,
while the **broad** provisioning grant may still be present — and that broad grant
is exactly what lets Conductor install the scoped one itself.

Conflating "the least-privilege grant is absent" with "no privilege is available"
is what turned a self-healing situation into a manual root errand.

## What now enforces it

| Mechanism | File |
|---|---|
| One door for every privileged op; attempts repair as the SSH user before anyone is asked for a credential | `ServerSudo.ensure!` |
| Repairs the wrapper set using the deploy user's own sudo | `ServerSudo.repair!` |
| Readiness takes an inventory instead of trusting one no-op wrapper | `ServerSudo.probe` / `#missing_wrappers` |
| Fails the build if any service outside registration tells a human to become root | `test/services/root_is_registration_only_test.rb` |
| Remediation states the automated path was already tried, so it cannot be read as a first resort | `ServerSudo.remediation` |

The test is the load-bearing one. This mistake was made by reading the codebase
and believing it — `remediation` opened with "Run this once as root", and every
caller trusted it. Prose gets re-derived and re-broken; a red build does not.

## The generalisable reflex

Before handing a human any privileged command, answer in code, not in your head:

> **Has the identity this system already holds actually been tried, and actually
> failed?**

If that has not been attempted, asking a person is not a fallback — it is a
skipped step. See [operate-as-deploy-not-root.md](operate-as-deploy-not-root.md)
for the adjacent rule about *which* identity does app-level work.
