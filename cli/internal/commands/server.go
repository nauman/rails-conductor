package commands

import (
	"fmt"
	"strings"

	"github.com/nauman/rails-conductor/cli/internal/appctx"
	"github.com/nauman/rails-conductor/cli/internal/exiterr"
	"github.com/nauman/rails-conductor/cli/internal/mcp"
	"github.com/nauman/rails-conductor/cli/internal/output"
	"github.com/spf13/cobra"
)

// NewServerCmd inspects one server.
func NewServerCmd() *cobra.Command {
	var probe bool
	cmd := &cobra.Command{
		Use:   "server <id-or-name>",
		Short: "Show one server in detail",
		Long: "Show one server: health, edge, SSH identity, stored audit and update\n" +
			"posture, cron jobs and hosted apps.\n\n" +
			"Accepts an id or a name, because a breadcrumb gives you an id and a\n" +
			"person typing has a name.",
		Args: cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			app := appctx.From(cmd.Context())
			if app == nil {
				return exiterr.New(exiterr.Usage, "the command was not initialized", "")
			}

			detail, err := app.API.Fleet().Server(cmd.Context(), args[0], probe)
			if err != nil {
				return err
			}

			return app.Out.OK(output.Response{
				Data:        normalizeServer(detail),
				Summary:     summarizeServer(detail),
				Notice:      serverNotice(detail, probe),
				Breadcrumbs: serverBreadcrumbs(detail),
			})
		},
	}
	cmd.Flags().BoolVar(&probe, "probe", false,
		"also run live SSH checks (slower; can time out on a loaded box)")
	return cmd
}

// serverDetailView is the CLI's shape for ONE server. It is deliberately not the
// same type as the row `status` renders: a list wants a scannable summary, a
// detail view wants everything, and collapsing them makes both worse.
//
// The SSH key is named, never carried — knowing WHICH key answers the operator's
// question; the key itself never needs to leave Conductor.
type serverDetailView struct {
	ID       int      `json:"id"`
	Name     string   `json:"name"`
	IP       string   `json:"ip"`
	Status   string   `json:"status"`
	Provider string   `json:"provider,omitempty"`
	Edge     string   `json:"edge"`
	CPU      string   `json:"cpu"`
	Memory   string   `json:"memory"`
	Disk     string   `json:"disk"`
	Load     float64  `json:"load"`
	Uptime   string   `json:"uptime"`
	LastSeen string   `json:"last_seen,omitempty"`
	SSH      string   `json:"ssh"`
	Audit    string   `json:"audit"`
	Updates  string   `json:"updates,omitempty"`
	Apps     []string `json:"apps"`
	CronJobs []string `json:"cron_jobs,omitempty"`
	Live     any      `json:"live,omitempty"`
}

func normalizeServer(d *mcp.ServerDetail) serverDetailView {
	apps := make([]string, 0, len(d.Apps))
	for _, a := range d.Apps {
		entry := fmt.Sprintf("%s (%s)", a.Name, a.Status)
		if a.Domain != "" {
			entry = fmt.Sprintf("%s — %s (%s)", a.Name, a.Domain, a.Status)
		}
		apps = append(apps, entry)
	}

	crons := make([]string, 0, len(d.CronJobs))
	for _, c := range d.CronJobs {
		state := "enabled"
		if !c.Enabled {
			state = "disabled"
		}
		crons = append(crons, fmt.Sprintf("%s — %s (%s, %s)", c.Name, c.Task, c.Schedule, state))
	}

	ssh := "not configured"
	if d.SSH.Configured {
		ssh = fmt.Sprintf("%s@%s:%d via %s", d.SSH.User, d.IP, d.SSH.Port, d.SSH.Key)
	}

	return serverDetailView{
		ID:       d.ID,
		Name:     d.Name,
		IP:       d.IP,
		Status:   d.Status,
		Provider: d.Provider,
		Edge:     edgeLabel(d.Edge),
		CPU:      fmt.Sprintf("%d%% of %d cores", d.Metrics.CPUPercent, d.Metrics.CPUCores),
		Memory:   d.Metrics.Memory,
		Disk:     fmt.Sprintf("%d%%", d.Metrics.Disk),
		Load:     d.Metrics.Load,
		Uptime:   d.Metrics.Uptime,
		LastSeen: d.Metrics.LastSeen,
		SSH:      ssh,
		Audit:    rollupLabel(d.Audit),
		Updates:  rollupLabel(d.Updates),
		Apps:     apps,
		CronJobs: crons,
		Live:     rawOrNil(d.Live),
	}
}

func edgeLabel(e mcp.Edge) string {
	if e.Detail != "" {
		return fmt.Sprintf("%s — %s", e.Type, e.Detail)
	}
	return e.Type
}

func rollupLabel(r mcp.Rollup) string {
	if r.LastStatus == "" {
		return "never run"
	}
	if r.LastAt == "" {
		return r.LastStatus
	}
	return fmt.Sprintf("%s (%s)", r.LastStatus, r.LastAt)
}

// summarizeServer leads with whatever is wrong, because that is what the reader
// opened this command to find.
func summarizeServer(d *mcp.ServerDetail) string {
	head := fmt.Sprintf("%s (%s) is %s", d.Name, d.IP, d.Status)

	var concerns []string
	if !strings.EqualFold(d.Status, "online") {
		concerns = append(concerns, "the server is not online")
	}
	if d.Metrics.Disk >= 85 {
		concerns = append(concerns, fmt.Sprintf("disk at %d%%", d.Metrics.Disk))
	}
	if strings.EqualFold(d.Audit.LastStatus, "attention") || strings.EqualFold(d.Audit.LastStatus, "at_risk") {
		concerns = append(concerns, "the audit wants attention")
	}
	stopped := 0
	for _, a := range d.Apps {
		if !strings.EqualFold(a.Status, "running") {
			stopped++
		}
	}
	if stopped > 0 {
		concerns = append(concerns, fmt.Sprintf("%s not running", plural(stopped, "app")))
	}

	if len(concerns) == 0 {
		return head + fmt.Sprintf(", hosting %s — nothing needs attention.", plural(len(d.Apps), "app"))
	}
	return head + ". Worth a look: " + strings.Join(concerns, ", ") + "."
}

// serverNotice says what the reader is NOT looking at. Stored rollups can be old,
// and presenting them without saying so invites acting on a stale picture.
func serverNotice(d *mcp.ServerDetail, probed bool) string {
	if probed {
		return ""
	}
	if d.Audit.LastAt == "" {
		return "Stored values only. Nothing has been probed live — pass --probe for live SSH checks."
	}
	return fmt.Sprintf("Stored values only; the audit above is from %s. Pass --probe for live SSH checks.", d.Audit.LastAt)
}

func serverBreadcrumbs(d *mcp.ServerDetail) []output.Breadcrumb {
	crumbs := []output.Breadcrumb{
		{Label: "Fleet health, server by server", Command: "conductor status"},
	}
	if len(d.Apps) > 0 {
		crumbs = append(crumbs, output.Breadcrumb{
			Label: "What needs attention right now", Command: "conductor situation",
		})
	}
	return crumbs
}

func rawOrNil(raw []byte) any {
	if len(raw) == 0 {
		return nil
	}
	return decodedOrRaw(raw)
}
