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
	"github.com/nauman/rails-conductor/cli/internal/auth"
	"github.com/nauman/rails-conductor/cli/internal/commands"
	"github.com/nauman/rails-conductor/cli/internal/config"
	"github.com/nauman/rails-conductor/cli/internal/exiterr"
	"github.com/nauman/rails-conductor/cli/internal/mcp"
	"github.com/nauman/rails-conductor/cli/internal/output"
	"github.com/nauman/rails-conductor/cli/internal/version"
)

// Commands that need no token carry this annotation.
const (
	annotationAuth     = "auth"
	annotationAuthSkip = "skip"
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

		// The token is resolved here, once, so every command sees the same
		// answer. A keyring read that FAILS is surfaced now rather than as a
		// puzzling 401 from whatever command happens to run first.
		//
		// Commands that need no token opt out: a locked keychain must not be
		// able to break `conductor version` or `--help`, which is exactly the
		// kind of failure that makes a tool feel broken for an unrelated reason.
		store := auth.SystemStore{}
		var token string
		source := auth.SourceNone
		if cmd.Annotations[annotationAuth] != annotationAuthSkip {
			var err error
			token, source, err = auth.Resolve(store, cfg.APIURL)
			if err != nil {
				return err
			}
		}
		if flags.verbose && source != auth.SourceNone {
			fmt.Fprintf(errOut, "config: token from %s\n", source)
		}

		cmd.SetContext(appctx.Into(cmd.Context(), &appctx.App{
			Config:      cfg,
			API:         mcp.New(cfg.APIURL, token),
			Out:         writer,
			Store:       store,
			TokenSource: source,
		}))
		return nil
	}

	root.AddCommand(commands.NewStatusCmd())
	root.AddCommand(commands.NewSituationCmd())
	root.AddCommand(commands.NewServerCmd())
	root.AddCommand(commands.NewAuthCmd())
	root.AddCommand(commands.NewVersionCmd())

	classifyUsageErrors(root)
	return root, writer
}

// classifyUsageErrors makes cobra's own validation failures exit 2, not 1.
//
// Cobra returns a plain error for "accepts 1 arg(s), received 0" and for an
// unknown flag. Untyped errors fall back to the generic API code, so a script
// could not tell "you typed it wrong" from "the backend failed" — which are the
// two things an exit code most needs to separate.
//
// Applied by walking the tree rather than per command, so a command added later
// inherits it instead of having to remember.
func classifyUsageErrors(cmd *cobraCommand) {
	cmd.SetFlagErrorFunc(func(_ *cobraCommand, err error) error {
		return exiterr.Wrap(exiterr.Usage, err, err.Error(), "Run with --help to see the accepted flags.")
	})

	if inner := cmd.Args; inner != nil {
		cmd.Args = func(c *cobraCommand, args []string) error {
			if err := inner(c, args); err != nil {
				return exiterr.Wrap(exiterr.Usage, err, err.Error(),
					fmt.Sprintf("Run `%s --help` for the expected arguments.", c.CommandPath()))
			}
			return nil
		}
	}

	for _, child := range cmd.Commands() {
		classifyUsageErrors(child)
	}
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
