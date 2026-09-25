# conductor

A CLI for operating a self-hosted Rails fleet through Conductor.

It talks to a Conductor instance's MCP endpoint — the same surface the agents
use — so anything the CLI reports, an agent can read, and vice versa.

## Install

**From a release** (no Go toolchain needed). Pick your platform from the
[latest release](https://github.com/nauman/rails-conductor/releases) and put the
binary on your `PATH`:

```sh
# macOS (Apple silicon)
curl -fsSL https://github.com/nauman/rails-conductor/releases/latest/download/conductor_0.1.0_darwin_arm64.tar.gz \
  | tar -xz -C /usr/local/bin conductor
```

Debian/RPM packages are attached to each release too, and install completions
alongside the binary.

**With Go:**

```sh
go install github.com/nauman/rails-conductor/cli/cmd/conductor@v0.1.0
```

The CLI is a nested module, so its tags are `cli/vX.Y.Z`. Go maps the `@vX.Y.Z`
you type onto that — you do not write the prefix.

**From source:**

```sh
make -C cli build      # ./cli/bin/conductor
make -C cli ci         # what the release gate runs
```

## Point it at your Conductor

Settings resolve flags → environment → `.conductor.json` in this directory or
above → `~/.conductor.json`. `--verbose` reports where each one came from, which
is the fastest way to find the config file you forgot about.

```sh
export CONDUCTOR_URL=https://conductor.example.com
conductor auth login          # stores the token in the OS keyring
conductor auth status
```

`conductor auth login` is the intended path: the token goes to the system
keyring, not to a dotfile and not to your shell history. `CONDUCTOR_MCP_TOKEN`
overrides it for CI, where there is no keyring.

Get a token from Conductor itself: **MCP tokens → Connect**.

## Use it

```sh
conductor fleet                    # every server, its apps, and their health
conductor situation                # what is in flight and what needs attention
conductor server <name>            # one server in detail
conductor version
```

Every command takes the same output flags:

| Flag | For |
| --- | --- |
| *(none)* | a human reading a terminal |
| `--json` | the full envelope: data, summary, breadcrumbs |
| `--quiet` | data only — no summary, no breadcrumbs |
| `--jq '<expr>'` | filter the envelope (implies `--json`) |
| `--markdown` | portable tables, for pasting into a doc or an issue |
| `--agent` | `--quiet --json`, the shape an agent wants |

Breadcrumbs are on purpose: the envelope says which Conductor answered, which
tool ran, and how long it took, so an unexpected number can be traced without
re-running anything.

## Exit codes

Scripts should branch on these rather than on message text.

| Code | Means |
| --- | --- |
| 0 | success |
| 1 | the operation failed |
| 2 | wrong usage — a bad flag, a missing argument |
| 3 | not authenticated, or the token was rejected |
| 4 | could not reach the Conductor instance |
| 5 | the thing asked for does not exist |

## Releasing

`bin/release-cli <version>` from the repo root. It runs the gate, builds every
platform as a snapshot, and only then tags and publishes — so a broken release
is refused before a tag exists rather than after one is public. The
`release-conductor` ritual in Conductor walks the whole checklist.

## More

- `cli/AGENTS.md` — the architecture, and the rules for adding a command
- `cli/API-COVERAGE.md` — which Conductor tools the CLI covers, and which it does not
- `cli/skills/conductor-cli/SKILL.md` — the agent-facing skill
