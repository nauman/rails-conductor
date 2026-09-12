// Package appctx carries the dependency handle through the command tree.
//
// Injected via context rather than package globals (GO_CLI_ARCHITECTURE §3a):
// a command's dependencies are then visible in its signature and swappable in a
// test, instead of being ambient state that every test has to reset.
package appctx

import (
	"context"

	"github.com/nauman/rails-conductor/cli/internal/config"
	"github.com/nauman/rails-conductor/cli/internal/mcp"
	"github.com/nauman/rails-conductor/cli/internal/output"
)

type key struct{}

// App is what every command needs and nothing more.
type App struct {
	Config *config.Config
	API    *mcp.Client
	Out    *output.Writer
}

// Into returns a context carrying app.
func Into(ctx context.Context, app *App) context.Context {
	return context.WithValue(ctx, key{}, app)
}

// From retrieves the App. It returns nil only if the root command failed to
// wire one, which is a programming error rather than a user-facing state.
func From(ctx context.Context) *App {
	app, _ := ctx.Value(key{}).(*App)
	return app
}
