package commands

import (
	"bufio"
	"fmt"
	"io"
	"strings"

	"github.com/nauman/rails-conductor/cli/internal/appctx"
	"github.com/nauman/rails-conductor/cli/internal/auth"
	"github.com/nauman/rails-conductor/cli/internal/exiterr"
	"github.com/nauman/rails-conductor/cli/internal/output"
	"github.com/spf13/cobra"
)

// NewAuthCmd groups token management.
func NewAuthCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "auth",
		Short: "Manage the Conductor token",
		Long: "Store a Conductor token in the OS keyring.\n\n" +
			"There is deliberately no --token flag: an argument is visible in `ps`,\n" +
			"lands in shell history, and is written into an agent's transcript.\n" +
			"The token is read from stdin instead.",
	}
	cmd.AddCommand(newAuthLoginCmd(), newAuthStatusCmd(), newAuthLogoutCmd())
	return cmd
}

func newAuthLoginCmd() *cobra.Command {
	var skipVerify bool
	cmd := &cobra.Command{
		Use:   "login",
		Short: "Store a token for this Conductor instance (reads it from stdin)",
		Example: "  printf %s \"$TOKEN\" | conductor auth login\n" +
			"  localvault exec --map CONDUCTOR.token=T -- sh -c 'printf %s \"$T\" | conductor auth login'",
		Args: cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			app := appctx.From(cmd.Context())
			if app == nil {
				return exiterr.New(exiterr.Usage, "the command was not initialized", "")
			}
			if app.Config.APIURL == "" {
				return exiterr.New(exiterr.Usage, "no Conductor URL configured",
					"Set CONDUCTOR_URL, or pass --api-url https://conductor.example.com")
			}

			token, err := readToken(cmd.InOrStdin())
			if err != nil {
				return err
			}

			// Verify BEFORE storing. Saving an unusable token converts a clear
			// failure now into a confusing one later, in a different command.
			if !skipVerify {
				probe := app.NewAPI(app.Config.APIURL, token)
				if _, err := probe.Fleet().Status(cmd.Context()); err != nil {
					return exiterr.Wrap(exiterr.CodeOf(err), err, "the token was not accepted",
						"Check the token and the URL. Use --skip-verify to store it anyway.")
				}
			}

			if err := auth.Save(app.Store, app.Config.APIURL, token); err != nil {
				return err
			}

			return app.Out.OK(output.Response{
				Data: map[string]any{
					"api_url":  app.Config.APIURL,
					"token":    auth.Fingerprint(token),
					"stored":   "keyring",
					"verified": !skipVerify,
				},
				Summary: fmt.Sprintf("Stored a token for %s in the keyring.", app.Config.APIURL),
				Breadcrumbs: []output.Breadcrumb{
					{Label: "Confirm what the CLI is using", Command: "conductor auth status"},
					{Label: "Fleet health, server by server", Command: "conductor fleet"},
				},
			})
		},
	}
	cmd.Flags().BoolVar(&skipVerify, "skip-verify", false, "store the token without checking it works")
	return cmd
}

func newAuthStatusCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "status",
		Short: "Show which token the CLI would use, and where it came from",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			app := appctx.From(cmd.Context())
			if app == nil {
				return exiterr.New(exiterr.Usage, "the command was not initialized", "")
			}

			token, source, err := auth.Resolve(app.Store, app.Config.APIURL)
			if err != nil {
				return err
			}

			data := map[string]any{
				"api_url": app.Config.APIURL,
				"source":  string(source),
				// The fingerprint is enough to tell two tokens apart and never
				// enough to use one.
				"token": auth.Fingerprint(token),
			}

			summary := "No token configured."
			crumbs := []output.Breadcrumb{
				{Label: "Store a token", Command: "conductor auth login"},
			}
			if token != "" {
				summary = fmt.Sprintf("Using a token from %s for %s.", source, app.Config.APIURL)
				crumbs = []output.Breadcrumb{
					{Label: "Fleet health, server by server", Command: "conductor fleet"},
				}
			}

			return app.Out.OK(output.Response{Data: data, Summary: summary, Breadcrumbs: crumbs})
		},
	}
}

func newAuthLogoutCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "logout",
		Short: "Remove this instance's token from the keyring",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			app := appctx.From(cmd.Context())
			if app == nil {
				return exiterr.New(exiterr.Usage, "the command was not initialized", "")
			}
			if err := auth.Forget(app.Store, app.Config.APIURL); err != nil {
				return err
			}

			notice := ""
			// Telling someone they are logged out while CONDUCTOR_MCP_TOKEN is
			// still set would be a lie: the next command still authenticates.
			if _, source, _ := auth.Resolve(app.Store, app.Config.APIURL); source == auth.SourceEnv {
				notice = "CONDUCTOR_MCP_TOKEN is still set in this environment, so commands will keep using it."
			}

			return app.Out.OK(output.Response{
				Data:    map[string]any{"api_url": app.Config.APIURL, "stored": false},
				Summary: fmt.Sprintf("Removed the keyring token for %s.", app.Config.APIURL),
				Notice:  notice,
			})
		},
	}
}

// readToken takes the token from stdin. It refuses an interactive terminal
// rather than prompting, because a prompt invites a paste into a place that
// echoes; piping is the habit worth enforcing.
func readToken(r io.Reader) (string, error) {
	reader := bufio.NewReader(r)
	raw, err := reader.ReadString('\n')
	if err != nil && err != io.EOF {
		return "", exiterr.Wrap(exiterr.Usage, err, "could not read the token from stdin",
			"Pipe it in: printf %s \"$TOKEN\" | conductor auth login")
	}
	token := strings.TrimSpace(raw)
	if token == "" {
		return "", exiterr.New(exiterr.Usage, "no token on stdin",
			"Pipe it in: printf %s \"$TOKEN\" | conductor auth login")
	}
	return token, nil
}
