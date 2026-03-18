#!/usr/bin/env bash

set -euo pipefail

required_files=(
  "docs/INDEX.md"
  "docs/README.md"
  "docs/dev/INDEX.md"
  "docs/dev/ROADMAP.md"
  "docs/dev/CHANGELOG.md"
  "docs/dev/FEATURES.md"
  "docs/dev/RALPH-METHODS.md"
  "docs/infra/INDEX.md"
)

missing=0
for file in "${required_files[@]}"; do
  if [[ ! -f "$file" ]]; then
    echo "Missing: $file"
    missing=1
  fi
done

if [[ $missing -eq 1 ]]; then
  echo "One or more required docs are missing."
  exit 1
fi

echo "Docs check passed."
