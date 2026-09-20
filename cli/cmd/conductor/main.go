// Command conductor is the CLI for a Conductor fleet.
//
// Deliberately tiny: everything lives under internal/, so nothing here is
// importable by another module. A CLI is an application, not a library.
package main

import (
	"context"
	"os"

	"github.com/nauman/rails-conductor/cli/internal/cli"
)

func main() {
	os.Exit(cli.Execute(context.Background()))
}
