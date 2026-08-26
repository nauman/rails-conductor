# A finding's remedy is a production action

**Date:** 2026-08-27
**Trigger:** A detector shipped that afternoon reported its second finding an hour
later. The finding named a container and said `docker stop <it>`. That container
was the only one serving that site.

## What happened

A new check flagged running containers labelled `conductor.candidate=true`. It was
written for a real incident — a candidate from an abandoned cutover had run
production jobs for fifteen days behind green health checks.

It shipped, and the next thing it found was a live production container.

Conductor's own deploy path leaves the *winning* container wearing
`conductor.candidate=true`; nothing relabels it once the deploy succeeds. So on a
healthy app, the container serving the site is a "candidate". The check could not
tell that apart from an abandoned experiment, and its remedy was a stop.

It also asserted, in the operator-facing text, that the container "takes no web
traffic, so health checks stay green" — a sentence that was true of the incident
it was written from and false of the very first thing it reported. **A detector
cannot know from labels whether something is serving.**

## The mistake underneath

The original check compared **revisions** and missed a superseded release whose
revision had not changed. The fix replaced that with **no comparison at all**.

That is not a fix. It is the same error with the guard removed — and it converted
a detector that missed things into one that accused innocent containers, which is
strictly worse, because the second kind gets acted on.

The right axis was always the **release**:

| Candidate's release | Meaning |
|---|---|
| differs from the app's current release | genuinely superseded — the real orphan |
| equals the app's current release | the live container wearing a stale label — a labelling bug |

## The rule

**Before shipping a finding, read its remedy as an instruction a tired person will
follow at 3am without re-deriving it.** Then ask what happens if the finding is
wrong. For a remedy that stops, deletes, or restarts anything, a false positive is
an outage — so the check must fail *safe*:

- **No basis for comparison means no accusation.** Missing recorded release, missing
  label, unreachable box — say nothing rather than guess. Silence is recoverable;
  a confident wrong instruction is not.
- **Never assert what the evidence cannot support.** "It takes no traffic" is not
  knowable from a container label. Describe what was observed, not what it implies.
- **Lead destructive remedies with the verification that would falsify them.**
  "VERIFY IT SERVES NOTHING FIRST" belongs before the command, not after it.

## Why it was caught

Only because the finding was read with the box in front of it — `docker ps` showed
no other container for that app, and the container's own logs showed it answering
requests. Nothing automated would have caught it, and the hourly sweep would have
kept repeating the instruction until someone followed it.

Related: [`root-is-a-registration-only-credential.md`](root-is-a-registration-only-credential.md)
(the adjacent rule about verifying before escalating), ADR 0006, ADR 0007.
