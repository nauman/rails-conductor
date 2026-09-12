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
		RunE: func(cmd *cobra.Command, _ []string) error {
			app := appctx.From(cmd.Context())
			return app.Out.OK(output.Response{
				Data:    map[string]any{"version": version.Version, "commit": version.Commit},
				Summary: "conductor " + version.String(),
			})
		},
	}
}
