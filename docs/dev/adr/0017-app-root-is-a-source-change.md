# 0017. Choosing the tree an app deploys from is a source change

Date: 2026-09-12

## Status

**Accepted (2026-09-12).** Extends the `:repository` capability to `app_root`,
introduced alongside monorepo support.

## Context

Conductor gained `app_root`: a monorepo keeps its Rails app below the repository
root, so the deploy path now separates the repository (where git operates) from the
app inside it (where Kamal and every config read operate).

That raised a question the UI had to answer immediately, because the field had to be
editable somewhere: **who may change it?**

The existing rule, from the editor-role work, is that `repository_url` is owner-only
while `branch` is not. The reasoning was recorded at the time: repointing an app at a
different repository means something owners rely on quietly starts building someone
else's code, whereas shipping a hotfix branch is exactly what the editor role is for.

`app_root` sits uncomfortably between those two. It does not change the repository,
which makes it look like ordinary config. But the tree it selects is the tree that
supplies:

- the **Dockerfile** — what gets built
- **config/deploy.yml** — the service name, image name, registry, target hosts and
  proxy hosts
- **.kamal/secrets** — which secrets are resolved, and under what names

A sibling directory in the same repository can therefore describe a completely
different application, built from different source, shipped to different hosts,
reading different secrets. The repository is identical; nothing else is.

The narrower reading — "it's just a path, and the repo is already trusted" — treats
the repository as the unit of trust. That holds for a single-app repo, where the repo
and the app are the same thing. It stops holding the moment a repository contains
more than one deployable app, which is precisely the case this field exists to
support. A monorepo is, by construction, a trust boundary *inside* a repository.

## Decision

**`app_root` requires the same `:repository` capability as `repository_url`.**

Both answer one question — *what source does this app deploy* — and the check is
written against that question rather than against either field, so a third field with
the same property joins the list rather than growing a third rule.

Setting a first `app_root`, changing it, and clearing it are all source changes.
Clearing is not a no-op: it repoints the app at the repository root, which is a
different tree from the one it was deploying.

## Consequences

An editor can still ship: `branch` remains editable, which is the hotfix path the
editor role exists for. What an editor cannot do is change *which application* the
app is, which is the same line ADR-era reasoning drew for `repository_url`.

A monorepo is configured once, by an owner, at setup — the moment that already
requires owner involvement for the repository itself. Ordinary operation is
unaffected, and the boundary tests assert that an unchanged `app_root` submitted
alongside an ordinary edit does not block that edit.

The cost is real but small: an editor adding a second app from an existing monorepo
needs an owner for that one field. That is the intended trade — the alternative lets
an editor silently redirect a production deploy to a different application without
touching anything an owner is watching.

## Alternatives considered

**Leave it editor-editable, like `branch`.** Rejected: `branch` moves an app along
its own history; `app_root` moves it to a different application. The analogy is to
`repository_url`, not to `branch`.

**A new, narrower capability (`:app_layout`).** Rejected as premature. It would be
one field's worth of policy, and the question it answers is already the question
`:repository` answers. If a third source-selecting field ever needs different
handling, that is the moment to split.

**Validate rather than authorize** — allow any operator, but constrain `app_root` to
directories that look like Rails apps. Rejected: it is a guess about intent, not a
permission, and a sibling Rails app is exactly the case that must not be waved
through.
