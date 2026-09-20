// Package version reports what build this is.
//
// Two paths, because there are two ways this binary comes into being:
//
//   - A RELEASE build has the values stamped in by ldflags.
//   - A `go install` or `go build` has nothing stamped, but the Go toolchain
//     embeds VCS information anyway. Reading that is the difference between a
//     bug report saying "dev" and one naming the commit it came from.
package version

import (
	"runtime/debug"
	"strings"
	"sync"
)

// Version is overwritten at release time:
//
//	-ldflags "-X github.com/nauman/rails-conductor/cli/internal/version.Version=v0.1.0"
var Version = ""

// Commit is the source revision, likewise injected at release time.
var Commit = ""

// Date is the build timestamp, injected at release time.
var Date = ""

var resolve sync.Once

// String renders what a human should paste into a bug report.
func String() string {
	fill()
	switch {
	case Commit == "":
		return Version
	case Date == "":
		return Version + " (" + Commit + ")"
	default:
		return Version + " (" + Commit + ", " + Date + ")"
	}
}

// Info returns the fields structurally, for the envelope.
func Info() map[string]any {
	fill()
	return map[string]any{"version": Version, "commit": Commit, "date": Date}
}

// fill completes anything ldflags did not set, from the embedded build info.
func fill() {
	resolve.Do(func() {
		info, ok := debug.ReadBuildInfo()
		if !ok {
			applyDefaults()
			return
		}

		// A module built by `go install module@v1.2.3` carries its version here.
		if Version == "" && info.Main.Version != "" && info.Main.Version != "(devel)" {
			Version = info.Main.Version
		}
		for _, setting := range info.Settings {
			switch setting.Key {
			case "vcs.revision":
				if Commit == "" {
					Commit = shortSHA(setting.Value)
				}
			case "vcs.time":
				if Date == "" {
					Date = setting.Value
				}
			case "vcs.modified":
				// An uncommitted tree is worth saying out loud: the commit alone
				// would otherwise describe a build that never existed.
				if setting.Value == "true" && !strings.HasSuffix(Commit, "-dirty") && Commit != "" {
					Commit += "-dirty"
				}
			}
		}
		applyDefaults()
	})
}

func applyDefaults() {
	if Version == "" {
		Version = "dev"
	}
}

func shortSHA(sha string) string {
	if len(sha) > 12 {
		return sha[:12]
	}
	return sha
}
