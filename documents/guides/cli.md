---
title: The conductor CLI
description: Install the CLI, point it at your Conductor, and read your fleet from a terminal or a script.
order: 9
---

# The conductor CLI

`conductor` is a terminal client for your Conductor instance. It talks to the
same MCP endpoint the agents use, so anything the CLI shows you, an agent can
read — and anything an agent reports, you can check yourself.

It is read-first by design. Fleet state, what is in flight, what needs
attention: the questions you ask during an incident, without opening a browser
and without SSH.

## Install

Every release publishes binaries for macOS, Linux and Windows, plus `.deb` and
`.rpm` packages. Take the one for your platform from the
[latest release](https://github.com/nauman/rails-conductor/releases/latest):

```sh
# macOS, Apple silicon
curl -fsSL https://github.com/nauman/rails-conductor/releases/latest/download/conductor_0.1.0_darwin_arm64.tar.gz \
  | tar -xz -C /usr/local/bin conductor
conductor version
```

The `.deb` and `.rpm` packages install shell completions alongside the binary.
The archives carry them under `completions/`.

If you have a Go toolchain:

```sh
go install github.com/nauman/rails-conductor/cli/cmd/conductor@v0.1.0
```

> The CLI lives in a subdirectory of the Conductor repo, so each release is
> tagged twice — `v0.1.0` and `cli/v0.1.0`. You type the first form; Go resolves
> the second. Nothing for you to do about it.

## Connect it to your Conductor

```sh
export CONDUCTOR_URL=https://conductor.example.com
conductor auth login
conductor auth status
```

`auth login` puts the token in your operating system's keyring — not in a
dotfile, and not in your shell history. Get the token from Conductor itself:
**MCP tokens → Connect**. It is the same token an agent would use, so treat it
the same way.

For CI, where there is no keyring, set `CONDUCTOR_MCP_TOKEN` and it takes
precedence.

Settings resolve in this order, and `--verbose` will tell you which one won:

1. flags
2. `CONDUCTOR_URL` / `CONDUCTOR_MCP_TOKEN`
3. `.conductor.json` in the current directory or any directory above it
4. `~/.conductor.json`

Named profiles (`--profile staging`) let one machine hold several instances.

## What you can ask it

```sh
conductor fleet        # every server, its apps, and their health
conductor situation    # what is deploying, what is stuck, what needs attention
conductor server web-1 # one server in detail
```

Each command takes the same output flags, so the same command serves a person
and a script:

| Flag | Gives you |
| --- | --- |
| *(none)* | a table meant for reading |
| `--json` | the full envelope: data, summary, breadcrumbs |
| `--quiet` | just the data |
| `--jq '.data.servers[].name'` | the envelope, filtered |
| `--markdown` | tables you can paste into an issue |
| `--agent` | `--quiet --json` |

The envelope's breadcrumbs say which Conductor answered, which tool ran and how
long it took. That is there so a number that surprises you can be traced without
running anything twice.

## Exit codes

Branch on these in a script rather than on message text — the text will change
and these will not.

| Code | Meaning |
| --- | --- |
| 0 | success |
| 1 | the operation failed |
| 2 | wrong usage: a bad flag, a missing argument |
| 3 | not authenticated, or the token was rejected |
| 4 | could not reach the Conductor instance |
| 5 | the thing you asked for does not exist |

```sh
if ! conductor situation --quiet >/dev/null; then
  case $? in
    3) echo "token expired — run: conductor auth login" ;;
    4) echo "conductor is unreachable" ;;
  esac
fi
```

## Upgrading

`conductor version` reports what you are running. Releases are deliberate — the
CLI does not ship on every merge — so check the
[releases page](https://github.com/nauman/rails-conductor/releases) rather than
expecting a prompt.

## If something looks wrong

- **`conductor auth status` says you are signed in and calls still return 3.**
  The token is valid for a different instance. Check `CONDUCTOR_URL`, and run
  any command with `--verbose` to see which config file supplied it.
- **Exit 4 with no detail.** The URL is reachable for your browser but not for
  the CLI — a VPN, or an instance behind an access proxy that expects a session
  cookie the CLI does not have.
- **A command exists in Conductor but not in the CLI.** The CLI covers a subset
  on purpose; `cli/API-COVERAGE.md` in the repo lists what is and is not
  covered, and why.
