package commands

import "github.com/nauman/rails-conductor/cli/internal/output"

// These expose the breadcrumb sets so the root package can assert every
// suggestion names a real command. They are the narrowest seam that makes that
// invariant testable without exporting the command internals.

// StatusBreadcrumbsForTest returns the breadcrumbs `status` can emit.
func StatusBreadcrumbsForTest() []output.Breadcrumb { return statusBreadcrumbs(nil) }

// SituationBreadcrumbsForTest returns the breadcrumbs `situation` can emit.
func SituationBreadcrumbsForTest() []output.Breadcrumb {
	return []output.Breadcrumb{{Label: "Fleet health, server by server", Command: "conductor status"}}
}

// AuthBreadcrumbsForTest returns every breadcrumb the auth commands can emit.
func AuthBreadcrumbsForTest() []output.Breadcrumb {
	return []output.Breadcrumb{
		{Label: "Confirm what the CLI is using", Command: "conductor auth status"},
		{Label: "Fleet health, server by server", Command: "conductor status"},
		{Label: "Store a token", Command: "conductor auth login"},
	}
}
