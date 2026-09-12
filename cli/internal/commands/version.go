package commands

import (
	"github.com/nauman/rails-conductor/cli/internal/appctx"
	"github.com/nauman/rails-conductor/cli/internal/output"
	"github.com/nauman/rails-conductor/cli/internal/version"
	"github.com/spf13/cobra"
)

// NewVersionCmd reports the build. It goes through the envelope like every
// other command so `--json` works here too.
func NewVersionCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "version",
		Short: "Show the CLI version",
		Args:  cobra.NoArgs,
		// Needs no token: a locked keychain must not break `version`.
		Annotations: map[string]string{"auth": "skip"},
		RunE: func(cmd *cobra.Command, _ []string) error {
			app := appctx.From(cmd.Context())
			return app.Out.OK(output.Response{
				Data:    version.Info(),
				Summary: "conductor " + version.String(),
			})
		},
	}
}
