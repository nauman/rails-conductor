# Release truth — what is actually deployed

Two checks answer questions Conductor could not previously answer about itself.
Both follow the **stored-rollup** pattern: a background job pays the SSH cost, and
request paths read what was stored. Neither probes on a request.

## Why this exists

Conductor learns about a release when *it* performs the deploy. An app deployed any
other way — a repo script, a CI job whose report is rejected, an operator on the box —
leaves the record frozen at the last thing Conductor saw. That record is then
presented as current truth.

On 2026-08-02 Conductor's newest record for InventList was a **failed** deploy from
07-28 against a **retired** box. An audit took that SHA as its release baseline and
reported the pending release as ~119 commits with two migrations needing a
lock-timeout protocol. Measured against the actually-running image: 26 commits, zero
pending migrations.

> **A stale record is more dangerous than a missing one, because it is trusted.**

## `ReleaseDriftDetector`

Compares the image SHA running on the box against the last **succeeded** deployment.

| Status | Meaning |
| --- | --- |
| `in_sync` | Record and box agree |
| `drift` | Box runs a different commit than Conductor recorded |
| `unrecorded` | Running something no successful deploy recorded — **no rollback possible** |
| `mixed_release` | Containers on different images — a roll stopped part-way |
| `not_running` | No app container (a lone datastore counts as not running) |
| `unknown` | Could not look, or the image carries a mutable tag |

Design rules, each learned the hard way:

- **Fails closed.** Reports `unknown`, never `in_sync`, when it cannot tell.
- **A failed deployment is never the recorded release.** That is exactly how a failure
  gets mistaken for a baseline.
- **Container lookup is name-based as well as label-based.** Containers Conductor did
  not start carry no service label — and those are the ones most likely to have drifted.
- **Accessories are not releases.** `<app>-db` on `pgvector:pg18` matches the app's name
  prefix and runs a mutable tag; counting it made every app with a database report
  "cannot identify the commit" — a wrong answer dressed as a careful one.
- **Separators are not identity.** An app slugged `calm-page` publishes to
  `naumantariq/calmpage` and runs `calmpage-web-…`.
- **More specific wins on a shared box.** The legacy scheme is `conductor-<slug>`, so the
  app whose slug is literally `conductor` otherwise claims every other app's container.

Surfaced in `FleetSituation` as `release_drift`. Swept hourly at :40.

### A mutable tag means no rollback

`unknown` on a `:latest` image is not a detector limitation — it is the finding. The box
cannot say what commit it runs, so **rollback is impossible regardless of how good the
rollback code is**, and that failure is silent until the moment you need it.

## `BackupRun` — per-attempt history

The `backups` row holds only the *latest* state, so a run dispatched and never executed
left no trace anywhere: it never started, so it never failed either. "Did this app back
up on the 31st?" had no record to consult.

`BackupRun` records one row per attempt, written at **dispatch**:

```
dispatched → running → completed | failed
```

A row stuck at `dispatched` is a job lost between the dispatcher and a worker;
`BackupRun.lost` finds them. `error_message` is mandatory on failure — a failed row with
no reason says something broke and nothing about what.

### `last_run_at` is stamped at the START of a run

It used to be written only on failure, which inverted every signal built on it:
`overdue?` called a nightly-succeeding backup stale, and `Backup.stuck` matched a healthy
run the instant it began. "When did this last run" is a question about the attempt, not
about whether the attempt worked.

## Related

- ADR [`0003`](adr/0003-one-deploy-path-kamal-as-contract.md) — one deploy path
- ADR [`0004`](adr/0004-stable-resource-ids-and-infra-revisions.md) — assigned identity
- Roadmap slot 31 — retire per-app deploy scripts, which removes the *cause* of `unrecorded`
