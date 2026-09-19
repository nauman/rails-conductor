package commands

import (
	"github.com/nauman/rails-conductor/cli/internal/mcp"
	"github.com/nauman/rails-conductor/cli/internal/output"
)

// These expose the breadcrumb sets so the root package can assert every
// suggestion names a real command. They are the narrowest seam that makes that
// invariant testable without exporting the command internals.

// FleetBreadcrumbsForTest returns the breadcrumbs `fleet` can emit, including the
// per-server crumb, which only appears when a server is not online.
func FleetBreadcrumbsForTest() []output.Breadcrumb {
	return fleetBreadcrumbs([]mcp.Server{{ID: 7, Name: "web-1", Status: "offline"}})
}

// ServerBreadcrumbsForTest returns the breadcrumbs `server` can emit.
func ServerBreadcrumbsForTest() []output.Breadcrumb {
	return serverBreadcrumbs(&mcp.ServerDetail{Apps: []mcp.App{{Name: "an-app"}}})
}

// SituationBreadcrumbsForTest returns the breadcrumbs `situation` can emit.
func SituationBreadcrumbsForTest() []output.Breadcrumb {
	return []output.Breadcrumb{{Label: "Fleet health, server by server", Command: "conductor fleet"}}
}

// AuthBreadcrumbsForTest returns every breadcrumb the auth commands can emit.
func AuthBreadcrumbsForTest() []output.Breadcrumb {
	return []output.Breadcrumb{
		{Label: "Confirm what the CLI is using", Command: "conductor auth status"},
		{Label: "Fleet health, server by server", Command: "conductor fleet"},
		{Label: "Store a token", Command: "conductor auth login"},
	}
}
