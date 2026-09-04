#!/usr/bin/env bash
# Close abandoned agent-browser sessions.
#
# WHY THIS IS NOT `close --all`
# -----------------------------
# This machine is shared by several agents, and `agent-browser close --all` cannot
# tell another agent's live session from an abandoned one — so running it mid-task
# kills someone else's browser. That is why sessions accumulate instead: the only
# safe option was to leave them, and sixteen piled up.
#
# WHAT THIS USES INSTEAD
# ----------------------
# Every session has a `<name>.sock` in ~/.agent-browser whose mtime is the last time
# the session was written. PID liveness is NOT a useful signal — these processes never
# exit on their own, so every session reads as alive however long it has been idle.
#
# CAVEAT, STATED RATHER THAN HIDDEN: mtime may reflect creation rather than last use.
# If so, this reaps by AGE, not idleness, and a legitimately long-lived session would
# be caught. That is acceptable given the house rule is to close a session when its
# task ends — a session older than the threshold is abandoned either way — but it is
# the reason the default is a dry run and the threshold is generous.
#
# Usage:
#   docs/scripts/reap-browser-sessions.sh            # report only (default)
#   docs/scripts/reap-browser-sessions.sh --close    # actually close them
#   docs/scripts/reap-browser-sessions.sh --days 7 --close
set -euo pipefail

DIR="${HOME}/.agent-browser"
DAYS=3
CLOSE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --close) CLOSE=1 ;;
    --days)  DAYS="$2"; shift ;;
    -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

[ -d "$DIR" ] || { echo "no agent-browser state at $DIR"; exit 0; }

current="$(agent-browser session 2>/dev/null | tail -1 | tr -d '[:space:]' || true)"
stale=0
kept=0

for sock in "$DIR"/*.sock; do
  [ -e "$sock" ] || continue
  name="$(basename "$sock" .sock)"

  # Never touch the session this shell is attached to, or the default one — the
  # default is what an agent gets when it forgets to pass --session, so closing it
  # breaks the next careless caller rather than the careless one that made it.
  if [ "$name" = "$current" ] || [ "$name" = "default" ]; then
    kept=$((kept + 1)); continue
  fi

  if [ -z "$(find "$sock" -mtime "+${DAYS}" 2>/dev/null)" ]; then
    kept=$((kept + 1)); continue
  fi

  age="$(date -r "$sock" '+%Y-%m-%d %H:%M' 2>/dev/null || echo unknown)"
  stale=$((stale + 1))

  if [ "$CLOSE" -eq 1 ]; then
    echo "closing  $name  (last written $age)"
    agent-browser --session "$name" close >/dev/null 2>&1 || echo "  ! close failed for $name"
  else
    echo "stale    $name  (last written $age)"
  fi
done

echo
echo "$stale stale (>${DAYS}d), $kept kept."
[ "$CLOSE" -eq 1 ] || echo "Dry run. Re-run with --close to close them."
