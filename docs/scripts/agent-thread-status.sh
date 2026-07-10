#!/usr/bin/env bash

# Report active thread obligations for one agent/session.
# Usage:
#   scripts/agent-thread-status.sh [docs-root] --me codex --me staff-engineer
#   AGENT_THREAD_ALIASES="codex,review" scripts/agent-thread-status.sh docs

set -euo pipefail

DOCS_ROOT=""
aliases=()

usage() {
  sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'
}

add_aliases() {
  local raw="$1"
  local item
  local old_ifs="$IFS"
  IFS=","
  for item in $raw; do
    item="$(printf '%s' "$item" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    item="${item#@}"
    [[ -n "$item" ]] && aliases+=("$item")
  done
  IFS="$old_ifs"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --me|--role|--alias)
      [[ $# -ge 2 ]] || { echo "$1 requires a value" >&2; exit 2; }
      add_aliases "$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --*)
      echo "unknown arg: $1" >&2
      exit 2
      ;;
    *)
      if [[ -n "$DOCS_ROOT" ]]; then
        echo "only one docs root may be provided" >&2
        exit 2
      fi
      DOCS_ROOT="$1"
      shift
      ;;
  esac
done

DOCS_ROOT="${DOCS_ROOT:-docs}"
if [[ ! -d "$DOCS_ROOT" ]]; then
  echo "docs root not found: $DOCS_ROOT" >&2
  exit 1
fi

if [[ ${#aliases[@]} -eq 0 && -n "${AGENT_THREAD_ALIASES:-}" ]]; then
  add_aliases "$AGENT_THREAD_ALIASES"
fi

DOCS_ROOT="$(cd "$DOCS_ROOT" && pwd)"

header_value() {
  local file="$1"
  local key="$2"
  sed -nE "s/^${key}:[[:space:]]*(.+)[[:space:]]*$/\\1/p" "$file" | head -1 | sed -E 's/[[:space:]]+$//'
}

normalize_awaiting() {
  sed -E 's/^@//; s/[[:space:]]+$//'
}

alias_match() {
  local name="$1"
  local alias
  for alias in "${aliases[@]}"; do
    [[ "$name" == "$alias" ]] && return 0
  done
  return 1
}

join_aliases() {
  local out=""
  local alias
  for alias in "${aliases[@]}"; do
    if [[ -z "$out" ]]; then
      out="$alias"
    else
      out="$out, $alias"
    fi
  done
  printf '%s\n' "${out:-none}"
}

owed=()
waiting=()
no_reply=()
parked=()

while IFS= read -r thread; do
  status="$(header_value "$thread" status)"
  awaiting="$(header_value "$thread" awaiting | normalize_awaiting)"
  updated="$(header_value "$thread" updated)"
  title="$(header_value "$thread" thread)"
  relative="${thread#"$DOCS_ROOT"/}"
  line="$relative | awaiting=${awaiting:-unknown} | updated=${updated:-unknown} | ${title:-untitled}"

  case "$status" in
    active)
      if [[ "$awaiting" == "-" ]]; then
        no_reply+=("$line")
      elif alias_match "$awaiting"; then
        owed+=("$line")
      else
        waiting+=("$line")
      fi
      ;;
    parked)
      parked+=("$line")
      ;;
  esac
done < <(find "$DOCS_ROOT" -path '*/threads/*.thread.md' -type f | sort)

print_section() {
  local title="$1"
  local array_name="$2"
  local count
  local i
  local item
  eval "count=\${#${array_name}[@]}"
  echo
  echo "$title ($count)"
  if [[ "$count" -eq 0 ]]; then
    echo "- none"
    return
  fi
  for ((i = 0; i < count; i++)); do
    eval "item=\${${array_name}[$i]}"
    echo "- $item"
  done
}

echo "Thread status - $DOCS_ROOT"
echo "aliases: $(join_aliases)"
print_section "OWED BY ME" owed
print_section "WAITING ON OTHERS" waiting
print_section "NO REPLY OWED" no_reply
print_section "PARKED" parked

echo
if [[ ${#owed[@]} -gt 0 ]]; then
  echo "Next action: reply to owed threads before unrelated work."
elif [[ ${#waiting[@]} -gt 0 ]]; then
  echo "Next action: do not sit idle; report who the thread is waiting on or run this command again after the other agent replies."
else
  echo "Next action: no active thread reply is owed by these aliases."
fi
