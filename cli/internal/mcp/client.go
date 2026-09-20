// Package mcp is the typed SDK the CLI talks through. Commands call methods
// here; they never build a request or read a status code themselves.
//
// Transport is JSON-RPC 2.0 `tools/call` over POST /mcp (plan 09 decision 3) —
// the same wire a native MCP client registers against, not the older REST-ish
// /mcp/call. The MCP tool inputs and results ARE the contract: already flat-enum,
// already audited, so the CLI needs no new Rails surface to exist.
//
// The server wraps a tool result in the MCP content envelope — the tool's own
// JSON arrives as TEXT inside content[0].text — so there are three failure layers
// to keep apart: HTTP status, a JSON-RPC `error`, and `isError` on an otherwise
// successful call. Collapsing them is how a tool refusal gets reported as a
// transport failure.
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

// protocolVersion is the MCP revision this client speaks. The server accepts a
// blank header, but sending it makes a future mismatch a clear 400 rather than a
// silently different interpretation of the same bytes.
const protocolVersion = "2025-06-18"

// rpcRequest is a single JSON-RPC 2.0 call. Batching was removed in MCP
// 2025-06-18 and the server rejects arrays, so this is never a slice.
type rpcRequest struct {
	JSONRPC string    `json:"jsonrpc"`
	ID      int       `json:"id"`
	Method  string    `json:"method"`
	Params  rpcParams `json:"params"`
}

type rpcParams struct {
	Name      string         `json:"name"`
	Arguments map[string]any `json:"arguments"`
}

// rpcResponse is the JSON-RPC envelope. `Error` is a protocol-level failure
// (unknown method, bad params); a TOOL failure arrives as a successful result
// with isError set.
type rpcResponse struct {
	JSONRPC string      `json:"jsonrpc"`
	ID      int         `json:"id"`
	Result  *toolResult `json:"result"`
	Error   *rpcError   `json:"error"`
}

type rpcError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

// toolResult is MCP's content envelope. The tool's own JSON is a string inside
// it, which is why unwrapping is a separate step from decoding the transport.
type toolResult struct {
	Content []struct {
		Type string `json:"type"`
		Text string `json:"text"`
	} `json:"content"`
	IsError bool `json:"isError"`
}

// Call invokes one MCP tool and returns the tool's own JSON. Every SDK method
// routes through here, so authentication, protocol framing, status mapping and
// unwrapping exist exactly once.
func (c *Client) Call(ctx context.Context, tool string, input map[string]any) (json.RawMessage, error) {
	if c.BaseURL == "" {
		return nil, exiterr.New(exiterr.Usage, "no Conductor URL configured",
			"Set CONDUCTOR_URL, or pass --api-url https://conductor.example.com")
	}
	if c.Token == "" {
		return nil, exiterr.New(exiterr.Auth, "no Conductor token configured",
			"Run `conductor auth login`, or set CONDUCTOR_MCP_TOKEN.")
	}
	if input == nil {
		input = map[string]any{}
	}

	body, err := json.Marshal(rpcRequest{
		JSONRPC: "2.0",
		ID:      1,
		Method:  "tools/call",
		Params:  rpcParams{Name: tool, Arguments: input},
	})
	if err != nil {
		return nil, exiterr.Wrap(exiterr.Usage, err, "could not encode the request", "")
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.BaseURL+"/mcp", bytes.NewReader(body))
	if err != nil {
		return nil, exiterr.Wrap(exiterr.Usage, err, "could not build the request", "")
	}
	req.Header.Set("Authorization", "Bearer "+c.Token)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")
	req.Header.Set("MCP-Protocol-Version", protocolVersion)

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
		return nil, statusError(resp.StatusCode, raw, c.redact)
	}

	var envelope rpcResponse
	if err := json.Unmarshal(raw, &envelope); err != nil {
		return nil, exiterr.Wrap(exiterr.API, err, "Conductor returned a response this CLI could not parse",
			"This usually means the URL is not a Conductor instance.")
	}

	// Protocol-level failure: the call never reached a tool.
	if envelope.Error != nil {
		return nil, exiterr.New(exiterr.API,
			fmt.Sprintf("Conductor rejected the call: %s", c.redact(envelope.Error.Message)),
			"This is a protocol error, not a tool refusal — the CLI and server may disagree on the wire.")
	}
	if envelope.Result == nil {
		return nil, exiterr.New(exiterr.API, "Conductor returned neither a result nor an error", "")
	}

	text := firstText(envelope.Result)

	// Tool-level refusal: the call reached the tool and it said no. That is an
	// API error, not a transport one, and the message is the tool's own.
	if envelope.Result.IsError {
		return nil, exiterr.New(exiterr.API, c.redact(strings.TrimSpace(text)), "")
	}
	if strings.TrimSpace(text) == "" {
		return nil, nil // a tool that legitimately returns nothing
	}
	return json.RawMessage(text), nil
}

// redact removes the bearer token from any text the SERVER produced before it
// reaches a log, an error message or the envelope.
//
// Defence in depth, not a known bug: Conductor does not echo the token. But a
// server error body is attacker-influenceable in general — a proxy, a WAF, a
// misconfigured error page — and every one of those strings is rendered
// verbatim to stderr. The cost of being wrong once is a credential in a
// terminal scrollback or a CI log.
func (c *Client) redact(text string) string {
	// Below minRedactableToken the substring is too short to be a credential and
	// long enough to appear by accident: redacting a one-character token rewrites
	// every message it touches. Caught by a test whose fixture token was "t",
	// which turned "App not found" into "App no[redacted] found".
	if text == "" || len(c.Token) < minRedactableToken {
		return text
	}
	return strings.ReplaceAll(text, c.Token, "[redacted]")
}

// Shorter than this is not a credential worth protecting, and redacting it costs
// more in mangled messages than it buys.
const minRedactableToken = 12

// firstText pulls the tool's payload out of MCP's content envelope. Only text
// parts carry it; anything else is ignored rather than guessed at.
func firstText(result *toolResult) string {
	for _, part := range result.Content {
		if part.Type == "text" {
			return part.Text
		}
	}
	return ""
}

// statusError turns a non-200 into a typed error, preferring the server's own
// message over a generic one when it sent a JSON error body.
func statusError(status int, raw []byte, redact func(string) string) error {
	code := exiterr.FromHTTPStatus(status)
	msg := fmt.Sprintf("Conductor returned HTTP %d", status)

	var payload struct {
		Error string `json:"error"`
	}
	if err := json.Unmarshal(raw, &payload); err == nil && payload.Error != "" {
		msg = redact(payload.Error)
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
