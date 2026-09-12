// Package cli builds the command tree and owns initialization.
//
// PersistentPreRunE does ALL of it — config, output negotiation, SDK wiring —
// before any RunE runs. Commands therefore start with their dependencies
// already resolved and stay thin enough to read in one sitting.
package cli

import (
	"context"
	"fmt"
	"os"

	"github.com/nauman/rails-conductor/cli/internal/appctx"
	"github.com/nauman/rails-conductor/cli/internal/commands"
	"github.com/nauman/rails-conductor/cli/internal/config"
	"github.com/nauman/rails-conductor/cli/internal/exiterr"
	"github.com/nauman/rails-conductor/cli/internal/mcp"
	"github.com/nauman/rails-conductor/cli/internal/output"
	"github.com/nauman/rails-conductor/cli/internal/version"
)

type rootFlags struct {
	json     bool
	jq       string
	quiet    bool
	agent    bool
	markdown bool
	apiURL   string
	profile  string
	verbose  bool
}

// NewRootCmd builds the tree. out/errOut are injected so tests can drive the
// real command tree without capturing process streams.
func NewRootCmd(out, errOut *os.File) (*cobraCommand, *output.Writer) {
	flags := &rootFlags{}
	writer := &output.Writer{Out: out, Err: errOut, Format: output.FormatAuto, IsTTY: isTTY(out)}

	root := newCommand("conductor", "Operate a self-hosted Rails fleet through Conductor")
	root.Long = "conductor talks to a Conductor instance's MCP endpoint.\n\n" +
		"Configuration comes from flags, then CONDUCTOR_URL / CONDUCTOR_MCP_TOKEN,\n" +
		"then .conductor.json in this directory or above, then ~/.conductor.json."
	root.Version = version.String()
	root.SilenceUsage = true  // a runtime failure is not a usage error
	root.SilenceErrors = true // main renders errors through the envelope

	pf := root.PersistentFlags()
	pf.BoolVar(&flags.json, "json", false, "output the JSON envelope")
	pf.StringVar(&flags.jq, "jq", "", "filter the JSON envelope with a jq expression (implies --json)")
	pf.BoolVar(&flags.quiet, "quiet", false, "output data only, without summary or breadcrumbs")
	pf.BoolVar(&flags.agent, "agent", false, "agent-friendly output (same as --quiet --json)")
	pf.BoolVar(&flags.markdown, "markdown", false, "output portable markdown tables")
	pf.StringVar(&flags.apiURL, "api-url", "", "Conductor base URL (overrides CONDUCTOR_URL)")
	pf.StringVar(&flags.profile, "profile", "", "named configuration profile")
	pf.BoolVar(&flags.verbose, "verbose", false, "report where each setting came from")

	root.PersistentPreRunE = func(cmd *cobraCommand, args []string) error {
		format, err := resolveFormat(flags)
		if err != nil {
			return err
		}
		writer.Format = format
		writer.JQ = flags.jq

		wd, _ := os.Getwd()
		cfg := config.Load(wd)
		cfg.SetAPIURL(flags.apiURL)
		cfg.SetProfile(flags.profile)

		if flags.verbose {
			for _, field := range []string{"api_url", "token", "profile"} {
				if source, ok := cfg.Sources[field]; ok {
					fmt.Fprintf(errOut, "config: %s from %s\n", field, source)
				}
			}
		}

		cmd.SetContext(appctx.Into(cmd.Context(), &appctx.App{
			Config: cfg,
			API:    mcp.New(cfg.APIURL, cfg.Token),
			Out:    writer,
		}))
		return nil
	}

	root.AddCommand(commands.NewStatusCmd())
	root.AddCommand(commands.NewSituationCmd())
	root.AddCommand(commands.NewVersionCmd())
	return root, writer
}

// resolveFormat collapses the output flags into one format, refusing a
// contradictory pair rather than silently picking a winner.
func resolveFormat(f *rootFlags) (output.Format, error) {
	chosen := 0
	for _, on := range []bool{f.json, f.quiet, f.markdown, f.agent} {
		if on {
			chosen++
		}
	}
	if chosen > 1 && !(f.agent && chosen == 1) {
		if !(f.agent && f.json && chosen == 2) && !(f.agent && f.quiet && chosen == 2) {
			return "", exiterr.New(exiterr.Usage, "choose one output format",
				"--json, --quiet, --markdown and --agent are mutually exclusive.")
		}
	}
	switch {
	case f.agent:
		return output.FormatJSON, nil
	case f.json:
		return output.FormatJSON, nil
	case f.quiet:
		return output.FormatQuiet, nil
	case f.markdown:
		return output.FormatMarkdown, nil
	default:
		return output.FormatAuto, nil
	}
}

// Execute runs the tree and returns the process exit code. main does nothing
// but call this and exit, so the exit path is testable.
func Execute(ctx context.Context) int {
	root, writer := NewRootCmd(os.Stdout, os.Stderr)
	if err := root.ExecuteContext(ctx); err != nil {
		return int(writer.Fail(err))
	}
	return int(exiterr.OK)
}
