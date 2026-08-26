thread:       a deploy hold's reason outlives the defect it names
participants: claude - operator - deploy
status:       open
awaiting:     operator
updated:      2026-08-26

# A deploy hold's reason outlives the defect it names

Opened after a hold blocked an app for 9 days past the fix it was waiting for, and
pointed at a build host the app's repo does not configure. The mechanism is
general, so it is written down here rather than left in one app's record.

### claude - the failure mode (2026-08-26)

A `deploy_hold_reason` is free text written at the moment of an incident, when the
cause is a hypothesis. Nothing re-checks it. So it hardens into the record and the
next agent reads a hypothesis as a finding.

Three ways the text drifts from reality, all seen in one hold:

**1. It names a fix as pending after that fix has shipped.** The hold said "keep
held until the build-before-stop safety release is live". That release landed the
day after the incident and had been running in production for 9 days. Nothing
connects a hold's stated exit condition to the commit that satisfies it, so the
hold cannot notice it is done.

**2. It names a cause the configuration contradicts.** The hold blamed building on
the serving host. `KamalDeployer#record_build_location` reads placement from the
app repo's `builder.remote`, the app does not set one, and Conductor's own
`builds_on` said "not recorded yet" — three sources agreeing against the hold
text, none of them consulted.

**3. It gets copied.** Two sibling apps carried the identical reason with no
incident of their own, because the text was pasted across a class of apps that
shared a shape. Now three records assert something untrue instead of one.

### claude - what actually diagnosed it (2026-08-26)

The deploy log, which nobody had reread:

```
#9 transferring context: 44.30MB 65.0s done
#9 CANCELED
=== deploy failed after stop-first — best-effort rebooting so the app isn't left down ===
```

The ordering is named by Conductor in its own log. The hold's narrative had drifted
around a line that was sitting there the whole time.

Worth noting what the log also reveals: the recovery path calls `kamal app boot`,
which falls back to the mutable `latest` tag. An app "recovered" that way keeps
serving an unidentifiable commit indefinitely, and shows up later as release drift
that reads like a configuration problem. It is incident residue — one clean deploy
clears it — but nothing says so, so it gets triaged as drift.

### claude - what would prevent it (2026-08-26)

Candidates, none built yet:

- **Verify a hold before enforcing it.** If a reason cites a commit or a release
  condition, check it at preflight time and mark the hold stale rather than
  blocking on prose.
- **Hold reasons should carry structure**, not only text — an exit condition the
  preflight can evaluate. Free text cannot be re-checked by anything.
- **A copied reason should be marked as copied.** A hold inherited from a sibling
  app is weaker evidence than one written from that app's own incident.
- **Distinguish incident residue from drift** in the release-drift finding, so a
  mutable tag booted by a recovery path is not triaged as a config mistake.

**Owed by operator:** whether any of the above is worth a roadmap slot. The
immediate instances are corrected; the mechanism that produced them is not.

**Fleet-specific detail for the affected apps is deliberately not in this repo.**
This repository is public — see `bin/privacy-check`. The per-app state lives in the
operator's private notes.
