// Package version carries the build-time version, injected via ldflags.
package version

// Version is overwritten at build time:
//
//	-ldflags "-X github.com/nauman/rails-conductor/cli/internal/version.Version=v0.1.0"
//
// "dev" is the honest answer for a binary built with plain `go build`.
var Version = "dev"

// Commit is the source revision, likewise injected. Empty when unset.
var Commit = ""

// String renders what a human should paste into a bug report.
func String() string {
	if Commit == "" {
		return Version
	}
	return Version + " (" + Commit + ")"
}
