---
title: Privileged server ops & passwordless sudo
description: How Conductor runs OS updates and reboots over SSH — and the security model behind the sudo grant.
order: 6
---

# Privileged server ops & sudo

## What this is for

A few fleet actions need **root** on the target server — **OS package updates** and
**reboots**. Conductor runs these over SSH, so it needs a way to become root on the
box without a human sitting at a password prompt.

## How Conductor does it

Conductor connects as the server's SSH user (`deploy` by default) and runs the
privileged command with `sudo -n` — **non-interactive** sudo, which never waits at a
password prompt. For that to work, the SSH user needs a **passwordless-sudo grant**
for those specific commands.

This is the same one-time setup Hatchbox performs when it provisions a server, and it
means **no permanent root SSH login** is required. If the grant is missing, the
server page's **Privileged ops readiness** panel shows *Setup needed* with the exact
one-time command to run (as root, once).

## Why it's scoped

Conductor never grants blanket `NOPASSWD: ALL` — that is just passwordless root. The
grant lists only the specific commands it needs (package tooling + reboot).

## Security: the caveat, and how to harden

Command-scoped `NOPASSWD` is a pragmatic default, but be aware of an important nuance:
**some tools can be escaped to a root shell even when the sudo rule is scoped to them.**
For example, `apt-get` is a documented [GTFOBins](https://gtfobins.org/gtfobins/apt-get/)
escape — `sudo apt-get changelog <pkg>` opens a pager you can shell out of, and a
`Dpkg::Pre-Invoke` hook runs arbitrary commands as root. So a `deploy` user with
`NOPASSWD: /usr/bin/apt-get` can, in principle, obtain a root shell — which defeats the
point of a limited deploy user.

If your threat model cares about that (a compromised `deploy` user should **not** be
able to become root), harden with one of these:

1. **Root-owned wrapper scripts (recommended).** Install small root-owned scripts
   (mode `0755`, not writable by `deploy`) that hardcode the exact operation with **no
   argument passthrough** — e.g. `/usr/local/sbin/conductor-apply-updates` and
   `/usr/local/sbin/conductor-reboot` — and grant `NOPASSWD` only on *those*. The
   deploy user can trigger the vetted actions but cannot inject arbitrary flags or
   spawn a shell.
2. **Separate privileged identity.** Give `deploy` **no** sudo at all, and let
   Conductor SSH as a dedicated `root`/admin key **only** for OS ops. Cleanest
   separation; costs a second key.
3. **Password-protected sudo (Hatchbox-classic style).** Keep full sudo but require a
   password, stored in Conductor's secret vault and passed via `sudo -S`. Matches
   Hatchbox classic, but it is full sudo — not least-privilege.

## How this compares to Hatchbox

Hatchbox's classic platform uses **password-protected sudo** for the deploy user (the
password is emailed at server creation) — not passwordless. Its newer platform runs a
server-side **agent as root** for automation. Either way, Hatchbox does not hand the
deploy user *blanket passwordless* sudo. The same principle applies here: grant the
narrowest thing that lets the automation work.

## References

- [GTFOBins — apt-get](https://gtfobins.org/gtfobins/apt-get/) (sudo shell escape)
- [Hatchbox — the deploy user's sudo password](https://hatchbox.relationkit.io/articles/7-what-is-the-sudo-password-for-the-deploy-user)
