package mcp

import (
	"context"
	"encoding/json"
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
