# Conductor Documentation

Project docs for Conductor (Rails 8 + Turbo + Importmaps + Tailwind). Start with `docs/INDEX.md` for the map and `AGENTS.md` for collaborator rules.

## Structure

```
.
├── docs/INDEX.md        # Doc map and usage notes
├── docs/README.md       # This file
├── docs/infra/          # Infrastructure and ops docs
│   └── INDEX.md
├── docs/plans/          # Vision-derived plans
│   └── INDEX.md
├── docs/analysis/       # Audits, gap maps, and current-state research
├── docs/sessions/       # Session logs and implementation history
├── docs/dev/            # Development docs
│   ├── INDEX.md
│   ├── ROADMAP.md
│   ├── CHANGELOG.md
│   ├── FEATURES.md
│   └── RALPH-METHODS.md
└── docs/scripts/        # Agent-friendly doc helpers
    ├── ralph-doc-loop.md
    ├── ralph-doc-prompt.sh
    └── ralph-doc-check.sh
```

## Usage

1. Read `docs/INDEX.md` for the right entry point.
2. Use `docs/plans/INDEX.md` as the master PRD and delivery map.
3. Use `docs/analysis/` to understand current reality before updating plans.
4. Use `docs/sessions/` to record what changed in a work session.
5. Keep docs concise, executable, and free of secrets.

## Notes

- The existing architecture draft lives at `caddy_ops_ui_architecture.md` and informs the plan and vision docs.
