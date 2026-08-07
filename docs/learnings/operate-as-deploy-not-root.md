# Operate as `deploy`, not `root` — root leaves files nothing else can write

**Found:** 2026-08-07 · **Trigger:** an agent running app-level commands over
`root@` SSH · **Status:** standard; enforcement is a gap

## The rule

| Task | User |
|---|---|
| Provisioning, hardening, OS updates, installing packages | `root` |
| Anything about a running app — deploys, `docker exec`, logs, dumps, editing app files, writing to app dirs | **`deploy`** |

The split is not ceremony. Root and deploy produce **different filesystem
state**, and only one of them is recoverable without root.

## Why root is corrosive here

A process running as root creates files owned by `root:root`. The app's
container, its `deploy`-owned systemd unit, and the next non-root operator then
cannot write them — and cannot fix the ownership either, because `chown` needs
root. So a single convenient `root` command leaves behind a **permanently stuck
artifact**: a log the app can no longer rotate, a `tmp/` entry it cannot clear, a
config it cannot rewrite, an upload dir that fails at the next write.

The failure never appears at the moment of the mistake. It appears at the next
deploy, or the next backup, or the first time the app tries to write there —
detached from the command that caused it, which is what makes it expensive.

This is the same shape as [form changes leave residue](form-changes-leave-residue.md):
an action that works, leaves state behind, and breaks something later that has no
obvious connection to it.

## For agents

**Default to `deploy@` for every app-level operation.** Reach for `root@` only
for provisioning, and say why when you do.

```bash
# App-level — as deploy
ssh deploy@<host> 'docker exec -i <container> bin/rails runner -' < script.rb

# Provisioning — root is correct
ssh root@<host> 'apt-get install -y awscli'
```

If `deploy` cannot do an app-level thing, that is a **provisioning bug to fix**
(add the user to the `docker` group, fix ownership, grant a scoped sudo rule) —
not a reason to escalate to root. Escalating hides the bug and adds residue.

Note that `docker exec` as root is *less* harmful than editing files as root —
the container's own user owns what it writes — but it still normalises a habit
whose failure mode is invisible, so it is not an exception.

## Known gaps in this fleet

- Some deploy scripts still run as `root` where a root-only env file blocks the
  switch. The fix is to move the env file to the deploy user (`chown deploy:deploy`,
  `chmod 600`), not to keep using root.
- Conductor does not currently **detect** root-owned residue in app directories.
  A server audit check — "files in the app dir not owned by the app user" — would
  catch it at the point it is cheap to fix.

## Related

- `docs/infra/edge-and-deploy-forms.md`
- `docs/plans/server-bootstrap.md`
