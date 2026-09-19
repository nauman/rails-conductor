// Package commands is the command surface: one file per noun.
package commands

import (
	"encoding/json"
	"fmt"
	"strings"

	"github.com/nauman/rails-conductor/cli/internal/appctx"
	"github.com/nauman/rails-conductor/cli/internal/exiterr"
	"github.com/nauman/rails-conductor/cli/internal/mcp"
	"github.com/nauman/rails-conductor/cli/internal/output"
	"github.com/spf13/cobra"
)

// NewStatusCmd reports fleet health: every server, its load and its apps.
func NewFleetCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "fleet",
		Short: "Show every server in the fleet with its apps and health",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			return runFleet(cmd)
		},
	}
	return cmd
}

func runFleet(cmd *cobra.Command) error {
	app := appctx.From(cmd.Context())
	if app == nil {
		return exiterr.New(exiterr.Usage, "the command was not initialized", "")
	}

	servers, err := app.API.Fleet().Status(cmd.Context())
	if err != nil {
		return err
	}

	return app.Out.OK(output.Response{
		Data:        normalizeServers(servers),
		Summary:     summarize(servers),
		Breadcrumbs: fleetBreadcrumbs(servers),
	})
}

// serverView is the CLI's own shape. Normalizing here rather than printing the
// SDK struct means the output contract does not move every time the API adds a
// field.
type serverView struct {
	ID     int      `json:"id"`
	Name   string   `json:"name"`
	IP     string   `json:"ip"`
	Status string   `json:"status"`
	Edge   string   `json:"edge"`
	CPU    string   `json:"cpu"`
	Memory string   `json:"memory"`
	Disk   string   `json:"disk"`
	Uptime string   `json:"uptime"`
	Apps   []string `json:"apps"`
}

func normalizeServers(servers []mcp.Server) []serverView {
	views := make([]serverView, 0, len(servers))
	for _, s := range servers {
		apps := make([]string, 0, len(s.Apps))
		for _, a := range s.Apps {
			apps = append(apps, fmt.Sprintf("%s (%s)", a.Name, a.Status))
		}
		views = append(views, serverView{
			ID:     s.ID,
			Name:   s.Name,
			IP:     s.IP,
			Status: s.Status,
			Edge:   s.Edge.Type,
			CPU:    fmt.Sprintf("%d%%", s.CPUPercent),
			Memory: s.Memory,
			Disk:   fmt.Sprintf("%d%%", s.Disk),
			Uptime: s.Uptime,
			Apps:   apps,
		})
	}
	return views
}

// summarize leads with what is wrong, because that is what the reader came for.
func summarize(servers []mcp.Server) string {
	if len(servers) == 0 {
		return "No servers registered."
	}
	offline, stopped, apps := 0, 0, 0
	for _, s := range servers {
		if !strings.EqualFold(s.Status, "online") {
			offline++
		}
		for _, a := range s.Apps {
			apps++
			if !strings.EqualFold(a.Status, "running") {
				stopped++
			}
		}
	}
	summary := fmt.Sprintf("%s, %s", plural(len(servers), "server"), plural(apps, "app"))
	if offline == 0 && stopped == 0 {
		return summary + " — all online and running."
	}
	var problems []string
	if offline > 0 {
		problems = append(problems, fmt.Sprintf("%d not online", offline))
	}
	if stopped > 0 {
		problems = append(problems, fmt.Sprintf("%d not running", stopped))
	}
	return summary + " — " + strings.Join(problems, ", ") + "."
}

// fleetBreadcrumbs suggest the next command. They are data, not help text, so
// an agent can follow them without parsing prose.
//
// Every breadcrumb must name a command that EXISTS — a suggestion that fails when
// followed is worse than silence. The per-server crumb was withheld until
// `conductor server` was written, and is asserted by
// TestEveryBreadcrumbNamesARegisteredCommand rather than remembered.
func fleetBreadcrumbs(servers []mcp.Server) []output.Breadcrumb {
	crumbs := []output.Breadcrumb{
		{Label: "What needs attention right now", Command: "conductor situation"},
	}
	// Point at the boxes worth opening, not at every box: a breadcrumb list as
	// long as the fleet is not a suggestion, it is the same table again.
	for _, s := range servers {
		if !strings.EqualFold(s.Status, "online") {
			crumbs = append(crumbs, output.Breadcrumb{
				Label:   fmt.Sprintf("Inspect %s, which is %s", s.Name, s.Status),
				Command: fmt.Sprintf("conductor server show %d", s.ID),
			})
		}
	}
	return crumbs
}

func plural(n int, noun string) string {
	if n == 1 {
		return fmt.Sprintf("%d %s", n, noun)
	}
	return fmt.Sprintf("%d %ss", n, noun)
}

// decodedOrRaw turns embedded JSON into something the renderer can walk, falling
// back to the raw string rather than dropping it.
func decodedOrRaw(raw []byte) any {
	var decoded any
	if err := json.Unmarshal(raw, &decoded); err != nil {
		return string(raw)
	}
	return decoded
}
