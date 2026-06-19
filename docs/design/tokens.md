# Conductor design system — "warm paper"

The visual direction for Conductor, extracted from the **Conductor Ops** and **Conductor Signal** mockups (2026-06-20). One system, light/warm-paper default; a dark theme will layer on the same token names. Source of truth: [`tokens.css`](tokens.css). Same house style as kuickr (Instrument Serif + warm tones) → consistent Pavelabs identity.

## Foundations

### Typography
| Role | Token | Font |
|---|---|---|
| Display / headings | `--font-display` | **Instrument Serif** (Georgia fallback) |
| UI / body | `--font-sans` | **Inter** |
| Data / code / metrics / IDs / logs | `--font-mono` | **JetBrains Mono** |

- **Scale** (`--text-*`, `--display-*`): dense ops scale — UI text 10–16px, display 24/34/46. Most labels 11–13px.
- **Tracking:** `--tracking-display` `-0.01em` (serif), `--tracking-label` `0.1em` and `--tracking-kicker` `0.14em` (UPPERCASE micro-labels).
- The serif-display ↔ dense-Inter contrast *is* the brand. Use Instrument Serif for page/section titles only.

### Color
Warm off-white neutrals + five semantic families, each `deep → default → bright → tint`:

| Family | Default | Deep (text on tint) | Bright (dot/accent) | Tint (badge bg) |
|---|---|---|---|---|
| Primary (forest) | `--color-primary` #3a5a3f | — | `--color-primary-strong` #2c7a4d | `--color-primary-tint` #e7f0e9 |
| Danger (terracotta) | `--color-danger` #a8443c | `--color-danger-deep` #7a1f1a | `--color-danger-bright` #d74b4b | `--color-danger-tint` #f7efee |
| Warning (amber) | `--color-warning` #8a6a1f | — | `--color-warning-bright` #e8a53b | `--color-warning-tint` #f5ebd3 |
| Info (slate blue) | `--color-info` #3a4f7a | — | `--color-info-bright` #7d97c4 | `--color-info-tint` #e2e7f1 |
| Accent (violet) | `--color-accent` #8b5cf6 | — | — | `--color-accent-tint` #ece6fb |

Neutrals: `--color-bg` #fafaf8 · `--color-surface` #fff · `--color-fill` #f1f0ec · `--color-border` #e4e3de (hairline) · text `--color-ink` #15161a / `--color-text` #3a3633 / `--color-text-muted` #6b7280 / `--color-text-faint` #9ca3af.

### Shape & elevation
- Radius: `--radius-control` 8 · `--radius-card` 12 · `--radius-large` 16 · `--radius-pill` 999 (50% for dots) · `--radius-chip` 4.
- Shadow: `--shadow-sm` / `--shadow-card` only — whisper-quiet. **Borders carry structure, not elevation. No gradients.**

## Patterns
- **Card** — `--color-surface`, `1px solid --color-border`, `--radius-card`, optional `--shadow-sm`. Composition over elevation.
- **Status dot** — circle (`border-radius:50%`) in `--status-healthy|down|warn|info|pending`.
- **Pill / badge** — `--radius-pill`, semantic *tint* bg + *deep/default* text (e.g. `--color-primary-tint` bg / `--color-primary` text).
- **Micro-label / kicker** — UPPERCASE, 10–11px, `--tracking-label`/`--tracking-kicker`, `--color-text-muted`.
- **Serif heading** — `--font-display`, `--display-*`, `--tracking-display`.
- **Mono data** — metrics, CPU/mem %, uptime, SHAs, log lines in `--font-mono`.
- **Deploy pipeline stepper** (from Signal) — step states: done → `--color-primary`, active → `--color-surface` fill with `--color-ink` label, pending → `--status-pending`.

## Concepts / IA the mockups surface
- **Ops view:** fleet overview · per-app status · metrics (CPU/mem/disk/uptime) · **audit log** · console.
- **Signal view:** **deploy → pipeline stepper → logs** · server · domain · proxy · health · backup.
- Emphasis on **deploy/logs/audit** — an agent/ops-trail-first console. Maps onto existing Conductor pages (Overview, Servers, Apps, Databases, Backups, Admin/MCP-calls); this is a restyle, not a re-architecture.

## Adoption notes
- Today's app uses Inter + Tailwind **slate** + `rounded-full` pills (`app/views/layouts/application.html.erb`). Migration = swap slate→warm neutrals, add the semantic families, introduce Instrument Serif for headings, load JetBrains Mono for data.
- Wire `tokens.css` `:root` vars into the Tailwind theme (`theme.extend.colors/fontFamily/borderRadius`) so utilities map to tokens.
- **Dark theme:** pending the dark mockup — it overrides the same var names under `[data-theme="dark"]` in `tokens.css`; components won't change.
