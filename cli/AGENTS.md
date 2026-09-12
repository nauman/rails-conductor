# conductor CLI — agent brief

Go CLI over Conductor's MCP endpoint. House standard:
`74-dev-docs/dev/cli/GO_CLI_ARCHITECTURE.md` — this file does not restate it.

## Structure

```
cmd/conductor/main.go   tiny: set version, call internal/cli.Execute
internal/cli/           cobra root; PersistentPreRunE does ALL init
internal/commands/      one file per noun; thin RunE → run func
internal/mcp/           the typed SDK (transport: POST /mcp/call)
internal/output/        the envelope, --jq, TTY-aware rendering
internal/exiterr/       typed errors + the stable exit-code enum
internal/config/        flags > env > project file > global file > defaults
internal/auth/          token resolution (env > keyring) + the keyring store
internal/appctx/        the dependency handle, injected via context
e2e/                    the real binary against a stub Conductor
```

## Dev loop

`change → make ci → fix → push`. `make ci` is the gate: fmt, vet, unit, e2e.

## Completeness bar

A new endpoint is **not done** until all five exist:

1. the command file under `internal/commands/`
2. its registration in `internal/cli/root.go`
3. a unit test **and** an e2e test asserting the exit code
4. a row in `API-COVERAGE.md`
5. the skill updated

A command without its coverage row is an unfinished change.

## Andon-cord

If a command needs something the SDK cannot express, **add the method to
`internal/mcp/`**. Never call raw HTTP or hand-decode JSON from a command. A
typed client stops being typed the first time one caller reaches past it.

## Rules that are not negotiable

- Commands never print. They return an `output.Response`; the writer renders it.
- Every success carries **breadcrumbs** — they are the discoverability surface
  for humans and agents alike, so they are data, not prose.
- Every error carries a **hint** and a §8 exit code. An error with no next step
  makes the user guess.
- Errors render **without** the `--jq` filter, so a broken filter cannot swallow
  the message explaining what broke.
- Exit codes are a contract. Append; never renumber.
- The token is environment- or keyring-supplied, resolved in `internal/auth`
  (env > keyring). It is never read from a config file and there is deliberately
  **no `--token` flag**: an argument is visible in `ps`, lands in shell history,
  and is written into an agent transcript. `conductor auth login` reads stdin.
- Never print a token. `auth.Fingerprint` renders enough to tell two apart and
  never enough to use one.
- A command that needs no token annotates `auth: skip`, so a locked keychain
  cannot break something unrelated like `version`.

## Releasing

`bin/release-cli 0.1.0` from the repo root. It runs the gate, tags `cli/v0.1.0`,
pushes the tag, and publishes with GoReleaser — in that order, so a red gate
refuses the release *before* a tag exists rather than after one is public.

Two constraints worth knowing before changing anything here:

- **The `cli/` tag prefix is a Go rule, not a preference.** This is a nested
  module, so `go install .../cli/cmd/conductor@v0.1.0` resolves only from a
  `cli/v0.1.0` tag.
- **The version travels in `CLI_VERSION`.** GoReleaser's `monorepo:` block
  handles prefixed tags but is a Pro feature, and `{{ .Version }}` would carry
  the slash into archive filenames. Every template uses `{{ .Env.CLI_VERSION }}`
  instead. `bin/release-cli` sets it; so does the workflow.

`make snapshot` builds every platform without publishing. Run it before tagging —
a tag is the one step that is awkward to take back.

`.github/workflows/release-cli.yml` is `workflow_dispatch` only and fires on
nothing. The local gate is the authority; the workflow is there in case hosted CI
becomes the better venue.

Not configured, deliberately: Homebrew/Scoop taps (no tap repo yet), cosign (no
keys), notarization (no Apple credentials). Each would fail at the last step of a
release, which is the worst place to discover a missing credential.
