package commands

import (
	"encoding/json"

	"github.com/nauman/rails-conductor/cli/internal/appctx"
	"github.com/nauman/rails-conductor/cli/internal/exiterr"
	"github.com/nauman/rails-conductor/cli/internal/output"
	"github.com/spf13/cobra"
)

// NewSituationCmd reports the resume point: what is in flight and what needs
// attention. It exists in this slice because `status` emits a breadcrumb
// pointing at it, and a breadcrumb to a command that does not exist is a defect.
func NewSituationCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "situation",
		Short: "Show what is in flight and what needs attention",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			app := appctx.From(cmd.Context())
			if app == nil {
				return exiterr.New(exiterr.Usage, "the command was not initialized", "")
			}

			raw, err := app.API.Fleet().Situation(cmd.Context())
			if err != nil {
				return err
			}

			// Passed through as decoded JSON rather than a struct: the situation
			// payload is broad and still moving, and a half-typed view would
			// silently drop the very field an operator needs to see.
			var data any
			if len(raw) > 0 {
				if err := json.Unmarshal(raw, &data); err != nil {
					return exiterr.Wrap(exiterr.API, err, "Conductor returned a situation this CLI could not parse", "")
				}
			}

			return app.Out.OK(output.Response{
				Data:    data,
				Summary: summarizeSituation(data),
				Breadcrumbs: []output.Breadcrumb{
					{Label: "Fleet health, server by server", Command: "conductor fleet"},
				},
			})
		},
	}
}

// summarizeSituation counts the worklist without claiming to understand it.
func summarizeSituation(data any) string {
	m, ok := data.(map[string]any)
	if !ok {
		return ""
	}
	inFlight := countKey(m, "in_flight")
	attention := countKey(m, "needs_attention")
	switch {
	case inFlight == 0 && attention == 0:
		return "Nothing in flight, nothing needing attention."
	case inFlight == 0:
		return plural(attention, "item") + " needing attention."
	default:
		return plural(inFlight, "operation") + " in flight, " + plural(attention, "item") + " needing attention."
	}
}

func countKey(m map[string]any, key string) int {
	if list, ok := m[key].([]any); ok {
		return len(list)
	}
	return 0
}
