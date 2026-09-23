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
password prompt. For that to work, the SSH user needs a **passwordless-sudo grant**.

Rather than granting `NOPASSWD` on general tools (see the security note below),
Conductor grants it **only on a few root-owned wrapper scripts** it installs:

- `/usr/local/sbin/conductor-apply-security-updates`
- `/usr/local/sbin/conductor-apply-all-updates`
- `/usr/local/sbin/conductor-reboot`
- `/usr/local/sbin/conductor-check` (a no-op used to probe readiness)

Each wrapper is root-owned (`0755`, not writable by `deploy`) and hardcodes its exact
operation with **no argument passthrough**. The `deploy` user can trigger the vetted
actions but cannot inject flags or spawn a shell. No permanent root SSH login is
required. If the grant is missing, the server page's **Privileged ops readiness**
panel shows *Setup needed* with the exact one-time command to run (as root, once).

## Why not just scope NOPASSWD to apt-get?

Because **command-scoped `NOPASSWD` on a general tool is still a root shell.** `apt-get`
is a documented [GTFOBins](https://gtfobins.org/gtfobins/apt-get/) escape — `sudo
apt-get changelog <pkg>` opens a pager you can shell out of, and a `Dpkg::Pre-Invoke`
hook runs arbitrary commands as root. So a `deploy` user with `NOPASSWD:
/usr/bin/apt-get` can obtain a root shell, which defeats the point of a limited deploy
user. The wrapper approach closes that hole: the sudoers rule points at a fixed script,
not a flexible tool.

## Stricter alternatives

If you want even tighter separation than the wrapper model:

1. **Separate privileged identity.** Give `deploy` **no** sudo at all, and let
   Conductor SSH as a dedicated `root`/admin key **only** for OS ops. Cleanest
   separation; costs a second key.
2. **Password-protected sudo (classic-PaaS style).** Keep full sudo but require a
   password, stored in Conductor's secret vault and passed via `sudo -S`. Matches
   a hosted Rails PaaS classic, but it is full sudo — not least-privilege.

## How this compares to a hosted Rails PaaS

a hosted Rails PaaS's classic platform uses **password-protected sudo** for the deploy user (the
password is emailed at server creation) — not passwordless. Its newer platform runs a
server-side **agent as root** for automation. Either way, a hosted Rails PaaS does not hand the
deploy user *blanket passwordless* sudo. The same principle applies here: grant the
narrowest thing that lets the automation work.

## References

- [GTFOBins — apt-get](https://gtfobins.org/gtfobins/apt-get/) (sudo shell escape)
- [a hosted Rails PaaS — the deploy user's sudo password](https://hatchbox.relationkit.io/articles/7-what-is-the-sudo-password-for-the-deploy-user)
