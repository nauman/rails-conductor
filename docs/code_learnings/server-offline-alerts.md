# Server offline alerts require confirmed loss

## Durable rules

- One SSH timeout is degraded reachability, not proof that a server is offline.
  Retry the connection inside the polling cycle and persist a dedicated failure
  streak; require a second consecutive failed cycle before crossing the
  offline/notification boundary. Do not overload the public `degraded` status as
  the counter because operators and other health checks can set it independently.
- A successful metrics sample resets `degraded` or `offline` state to `online`.
  Offline mail remains transition-only so a continuing outage cannot send one
  message every polling interval.
- Metrics and per-app container probes share a Solid Queue concurrency group
  keyed by server. This serializes SSH reads for one host while preserving
  concurrency across different hosts.
- Intentional reboot grace remains stronger than failure counting: no failed
  poll during the grace window may degrade, mark offline, or notify.
- Resource findings such as full swap are separate health warnings. They may
  explain latency, but they do not turn a single reachability timeout into a
  confirmed outage.

## Incident context

At 02:00 UTC on 2026-08-13, the metrics and container schedules aligned and
opened several SSH probes to one six-app host. One metrics connection and one
app-status connection hit the 10-second Net::SSH timeout. The old metrics job
immediately marked the host offline and sent email; a manual probe roughly one
minute later succeeded, and every public app remained reachable.

The regression contract now covers retry success, first-cycle degradation,
second-cycle offline notification, successful reset, and the shared per-server
concurrency key.
