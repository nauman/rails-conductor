// Package appctx carries the dependency handle through the command tree.
//
// Injected via context rather than package globals (GO_CLI_ARCHITECTURE §3a):
// a command's dependencies are then visible in its signature and swappable in a
// test, instead of being ambient state that every test has to reset.
package appctx

import (
	"context"

	"github.com/nauman/rails-conductor/cli/internal/auth"
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
	Store  auth.Store

	// TokenSource records where API's token came from, for `auth status` and
	// --verbose. It is the source, never the token.
	TokenSource auth.Source

	// newAPI builds a client for a token other than the resolved one — used by
	// `auth login` to verify a candidate token before storing it.
	newAPI func(apiURL, token string) *mcp.Client
}

// NewAPI returns a client for an arbitrary token.
func (a *App) NewAPI(apiURL, token string) *mcp.Client {
	if a.newAPI != nil {
		return a.newAPI(apiURL, token)
	}
	return mcp.New(apiURL, token)
}

// SetAPIFactory overrides client construction. Tests use it to keep `auth
// login` away from the network.
func (a *App) SetAPIFactory(f func(apiURL, token string) *mcp.Client) { a.newAPI = f }

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
