#!/usr/bin/env bash

cat <<'PROMPT'
You are helping update Conductor docs.

- Read docs/INDEX.md, docs/dev/INDEX.md, docs/infra/INDEX.md
- Update only the files requested.
- Keep instructions concise, executable, and free of secrets.
- Update indexes when adding docs.

Output: summary, files changed, and any open questions.
PROMPT
