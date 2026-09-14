package mcp

import (
	"context"
	"encoding/json"
	"strconv"
)

// Edge is how traffic reaches a server's apps. Deploy method and edge are
// independent axes, so this is reported per server, not derived from the app.
type Edge struct {
	Type   string `json:"type"`
	Detail string `json:"detail"`
}

// App is a server's view of an app — enough to answer "what is on this box",
// not the app's full record.
type App struct {
	Name         string `json:"name"`
	Status       string `json:"status"`
	Domain       string `json:"domain"`
	DeployMethod string `json:"deploy_method"`
	Port         *int   `json:"port"`
	Notes        string `json:"notes"`
}

// Server is one fleet host.
type Server struct {
	ID         int     `json:"id"`
	Name       string  `json:"name"`
	IP         string  `json:"ip"`
	Status     string  `json:"status"`
	Provider   string  `json:"provider"`
	CPUPercent int     `json:"cpu_percent"`
	CPUCores   int     `json:"cpu_cores"`
	Memory     string  `json:"memory"`
	Disk       int     `json:"disk"`
	Load       float64 `json:"load"`
	Uptime     string  `json:"uptime"`
	LastSeen   string  `json:"last_seen"`
	Edge       Edge    `json:"edge"`
	Apps       []App   `json:"apps"`
}

// FleetService groups the read-only fleet calls.
type FleetService struct{ c *Client }

// Fleet returns the fleet read surface.
func (c *Client) Fleet() *FleetService { return &FleetService{c: c} }

// Status returns every server with its apps and health.
func (s *FleetService) Status(ctx context.Context) ([]Server, error) {
	raw, err := s.c.Call(ctx, "conductor_read", map[string]any{"action": "fleet_status"})
	if err != nil {
		return nil, err
	}
	var servers []Server
	if err := decodeInto(raw, &servers); err != nil {
		return nil, err
	}
	return servers, nil
}

// Situation is the resume point: what is in flight and what needs attention.
// Held as raw JSON deliberately — its shape is broad and still moving, and a
// half-typed struct would silently drop fields the operator needs to see.
func (s *FleetService) Situation(ctx context.Context) (json.RawMessage, error) {
	return s.c.Call(ctx, "conductor_read", map[string]any{"action": "situation"})
}

// Metrics is a server's current resource picture.
type Metrics struct {
	CPUPercent int     `json:"cpu_percent"`
	CPUCores   int     `json:"cpu_cores"`
	Memory     string  `json:"memory"`
	Disk       int     `json:"disk"`
	Load       float64 `json:"load"`
	Uptime     string  `json:"uptime"`
	UpdatedAt  string  `json:"updated_at"`
	LastSeen   string  `json:"last_seen"`
}

// Rollup is a stored outcome — the last audit, update run or harden. Conductor's
// own record of an operation, not a live probe.
type Rollup struct {
	LastStatus string `json:"last_status"`
	LastAt     string `json:"last_at"`
	LastScope  string `json:"last_scope"`
}

// SSH is how Conductor reaches the box. The key is named, never carried.
type SSH struct {
	User       string `json:"user"`
	Port       int    `json:"port"`
	Key        string `json:"key"`
	Configured bool   `json:"configured"`
}

// CronJob is a scheduled task Conductor manages on the server.
type CronJob struct {
	ID       int    `json:"id"`
	Name     string `json:"name"`
	Scope    string `json:"scope"`
	App      string `json:"app"`
	Task     string `json:"task"`
	Schedule string `json:"schedule"`
	Cron     string `json:"cron"`
	Enabled  bool   `json:"enabled"`
}

// Recovery is what Conductor did the last time the box came back.
type Recovery struct {
	LastAt string `json:"last_at"`
	Report string `json:"report"`
}

// ServerDetail is one server in full.
//
// `Live` stays raw: it only appears when probe:true was asked for, its shape is
// broad and still moving, and a half-typed view would drop the very field an
// operator went looking for.
type ServerDetail struct {
	ID       int             `json:"id"`
	Name     string          `json:"name"`
	IP       string          `json:"ip"`
	Status   string          `json:"status"`
	Provider string          `json:"provider"`
	Region   string          `json:"region"`
	Edge     Edge            `json:"edge"`
	Metrics  Metrics         `json:"metrics"`
	Audit    Rollup          `json:"audit"`
	Updates  Rollup          `json:"updates"`
	Harden   Rollup          `json:"harden"`
	Recovery Recovery        `json:"recovery"`
	SSH      SSH             `json:"ssh"`
	CronJobs []CronJob       `json:"cron_jobs"`
	Apps     []App           `json:"apps"`
	Live     json.RawMessage `json:"live,omitempty"`
}

// Server returns one server's detail. The reference is an id or a name; the
// caller need not know which, because an operator reading a breadcrumb has an
// id and an operator typing has a name.
//
// probe runs live SSH checks on top of the stored record. It is slower and can
// time out on a loaded box, so it is opt-in.
func (s *FleetService) Server(ctx context.Context, reference string, probe bool) (*ServerDetail, error) {
	input := map[string]any{"action": "server"}
	if id, err := strconv.Atoi(reference); err == nil {
		input["server_id"] = id
	} else {
		input["server_name"] = reference
	}
	if probe {
		input["probe"] = true
	}

	raw, err := s.c.Call(ctx, "conductor_read", input)
	if err != nil {
		return nil, err
	}
	var detail ServerDetail
	if err := decodeInto(raw, &detail); err != nil {
		return nil, err
	}
	return &detail, nil
}
