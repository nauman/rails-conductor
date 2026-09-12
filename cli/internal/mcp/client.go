// Package mcp is the typed SDK the CLI talks through. Commands call methods
// here; they never build a request or read a status code themselves.
//
// Transport v1 is Conductor's existing /mcp endpoint (plan 09 decision 3). The
// MCP tool inputs and results ARE the contract — they are already flat-enum and
// already audited — so the CLI needs no new Rails surface to exist.
//
// Andon-cord (GO_CLI_ARCHITECTURE §4): if a command needs something this SDK
// cannot express, add the method HERE. A command that reaches past the SDK to
// raw JSON is how a typed client quietly stops being typed.
package mcp

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/nauman/rails-conductor/cli/internal/exiterr"
)

// Client calls Conductor's MCP tool endpoint.
type Client struct {
	BaseURL string
	Token   string
	HTTP    *http.Client
}

// New builds a client. The timeout is generous because fleet reads cross SSH to
// real servers; it is not a local API.
func New(baseURL, token string) *Client {
	return &Client{
		BaseURL: strings.TrimRight(baseURL, "/"),
		Token:   token,
		HTTP:    &http.Client{Timeout: 120 * time.Second},
	}
}

// toolRequest is the POST /mcp/call body Conductor expects.
type toolRequest struct {
	Name  string         `json:"name"`
	Input map[string]any `json:"input"`
}

// toolResponse carries either a result or a server-rendered error.
type toolResponse struct {
	Result json.RawMessage `json:"result"`
	Error  string          `json:"error"`
}

// Call invokes one MCP tool and decodes its result. Every SDK method routes
// through here, so authentication, status mapping and decoding exist once.
func (c *Client) Call(ctx context.Context, tool string, input map[string]any) (json.RawMessage, error) {
	if c.BaseURL == "" {
		return nil, exiterr.New(exiterr.Usage, "no Conductor URL configured",
			"Set CONDUCTOR_URL, or pass --api-url https://conductor.example.com")
	}
	if c.Token == "" {
		return nil, exiterr.New(exiterr.Auth, "no Conductor token configured",
			"Set CONDUCTOR_MCP_TOKEN to an MCP/API bearer token.")
	}
	if input == nil {
		input = map[string]any{}
	}

	body, err := json.Marshal(toolRequest{Name: tool, Input: input})
	if err != nil {
		return nil, exiterr.Wrap(exiterr.Usage, err, "could not encode the request", "")
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.BaseURL+"/mcp/call", bytes.NewReader(body))
	if err != nil {
		return nil, exiterr.Wrap(exiterr.Usage, err, "could not build the request", "")
	}
	req.Header.Set("Authorization", "Bearer "+c.Token)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")

	resp, err := c.HTTP.Do(req)
	if err != nil {
		return nil, exiterr.Wrap(exiterr.Network, err, fmt.Sprintf("could not reach Conductor at %s", c.BaseURL),
			"Check the URL and that the instance is up.")
	}
	defer resp.Body.Close()

	raw, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, exiterr.Wrap(exiterr.Network, err, "could not read the response", "")
	}

	if resp.StatusCode != http.StatusOK {
		return nil, statusError(resp.StatusCode, raw)
	}

	var decoded toolResponse
	if err := json.Unmarshal(raw, &decoded); err != nil {
		return nil, exiterr.Wrap(exiterr.API, err, "Conductor returned a response this CLI could not parse",
			"This usually means the URL is not a Conductor instance.")
	}
	if decoded.Error != "" {
		// A tool-level refusal: the call reached Conductor and it said no. That
		// is an API error, not a transport one, and the message is the server's.
		return nil, exiterr.New(exiterr.API, decoded.Error, "")
	}
	return decoded.Result, nil
}

// statusError turns a non-200 into a typed error, preferring the server's own
// message over a generic one when it sent a JSON error body.
func statusError(status int, raw []byte) error {
	code := exiterr.FromHTTPStatus(status)
	msg := fmt.Sprintf("Conductor returned HTTP %d", status)

	var payload struct {
		Error string `json:"error"`
	}
	if err := json.Unmarshal(raw, &payload); err == nil && payload.Error != "" {
		msg = payload.Error
	}

	hint := ""
	switch code {
	case exiterr.Auth:
		hint = "The token was rejected. Check CONDUCTOR_MCP_TOKEN."
	case exiterr.Forbidden:
		hint = "The token is valid but lacks the capability for this action."
	case exiterr.NotFound:
		hint = "Check the name or id, and that it belongs to this organization."
	case exiterr.RateLimit:
		hint = "Slow down and retry."
	}
	return exiterr.New(code, msg, hint)
}

// decodeInto is shared by the typed methods below.
func decodeInto[T any](raw json.RawMessage, target *T) error {
	if len(raw) == 0 {
		return nil
	}
	if err := json.Unmarshal(raw, target); err != nil {
		return exiterr.Wrap(exiterr.API, err, "Conductor returned a result this CLI could not parse",
			"The tool's shape may have changed; update the CLI.")
	}
	return nil
}
