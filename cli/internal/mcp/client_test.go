package mcp

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/nauman/rails-conductor/cli/internal/exiterr"
)

// Asserts the JSON-RPC wire itself. The previous version asserted /mcp/call and
// a {name,input} body, so it would have passed while the CLI spoke a transport
// the server does not implement — a test that confirmed the bug.
// rpcOK wraps a tool payload in MCP's content envelope the way the server does:
// the tool's JSON is a STRING inside content[0].text. Built rather than
// hand-escaped, because hand-escaped JSON in a test is where typos hide.
// A realistic token length, so no test depends on redaction's minimum.
const testToken = "tok_test_9f3c2a7e5b1d"

func rpcOK(t *testing.T, payload string) string {
	t.Helper()
	encoded, err := json.Marshal(payload)
	if err != nil {
		t.Fatalf("could not encode the payload: %v", err)
	}
	return `{"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":` + string(encoded) + `}],"isError":false}}`
}

func TestCallSpeaksJSONRPCToolsCall(t *testing.T) {
	var gotAuth, gotPath, gotProtocol string
	var gotBody rpcRequest

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotAuth = r.Header.Get("Authorization")
		gotPath = r.URL.Path
		gotProtocol = r.Header.Get("MCP-Protocol-Version")
		_ = json.NewDecoder(r.Body).Decode(&gotBody)
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(rpcOK(t, "[]")))
	}))
	defer srv.Close()

	if _, err := New(srv.URL, "tok_abcdefghijkl").Fleet().Status(context.Background()); err != nil {
		t.Fatalf("Status returned %v", err)
	}
	if gotPath != "/mcp" {
		t.Errorf("the MCP transport is POST /mcp, got %q", gotPath)
	}
	if gotBody.JSONRPC != "2.0" || gotBody.Method != "tools/call" {
		t.Errorf("expected a JSON-RPC tools/call, got %+v", gotBody)
	}
	if gotBody.Params.Name != "conductor_read" || gotBody.Params.Arguments["action"] != "fleet_status" {
		t.Errorf("the tool and action belong in params, got %+v", gotBody.Params)
	}
	if gotAuth != "Bearer tok_abcdefghijkl" {
		t.Errorf("expected a bearer token, got %q", gotAuth)
	}
	if gotProtocol == "" {
		t.Error("the MCP-Protocol-Version header should be sent so a mismatch is a clear 400")
	}
}

// The tool's payload arrives as TEXT inside MCP's content envelope, not as the
// result itself. Unwrapping the wrong layer yields a parse error at the caller.
func TestCallUnwrapsTheContentEnvelope(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(rpcOK(t, `[{"id":4,"name":"web-1"}]`)))
	}))
	defer srv.Close()

	servers, err := New(srv.URL, testToken).Fleet().Status(context.Background())
	if err != nil {
		t.Fatalf("Status returned %v", err)
	}
	if len(servers) != 1 || servers[0].Name != "web-1" {
		t.Errorf("the tool payload did not survive unwrapping: %+v", servers)
	}
}

// Three failure layers must stay distinct: HTTP status, a JSON-RPC error, and
// isError on an otherwise successful call.
func TestJSONRPCErrorIsNotATransportFailure(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"Method not found"}}`))
	}))
	defer srv.Close()

	_, err := New(srv.URL, testToken).Fleet().Status(context.Background())
	if err == nil {
		t.Fatal("a JSON-RPC error must fail the call")
	}
	if !strings.Contains(err.Error(), "Method not found") {
		t.Errorf("the protocol error should reach the user, got %q", err.Error())
	}
}

func TestStatusDecodesServers(t *testing.T) {
	payload := `[{"id":4,"name":"box","status":"online","cpu_percent":7,"disk":29,` +
		`"edge":{"type":"kamal_proxy"},"apps":[{"name":"kuickr","status":"running"}]}]`
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(rpcOK(t, payload)))
	}))
	defer srv.Close()

	servers, err := New(srv.URL, testToken).Fleet().Status(context.Background())
	if err != nil {
		t.Fatalf("Status returned %v", err)
	}
	if len(servers) != 1 {
		t.Fatalf("expected 1 server, got %d", len(servers))
	}
	s := servers[0]
	if s.ID != 4 || s.Name != "box" || s.Edge.Type != "kamal_proxy" {
		t.Errorf("server decoded wrong: %+v", s)
	}
	if len(s.Apps) != 1 || s.Apps[0].Name != "kuickr" {
		t.Errorf("apps decoded wrong: %+v", s.Apps)
	}
}

// Each status must produce its own exit code — this is what scripts branch on.
func TestHTTPStatusBecomesTheRightExitCode(t *testing.T) {
	cases := []struct {
		status int
		want   exiterr.Code
	}{
		{http.StatusUnauthorized, exiterr.Auth},
		{http.StatusForbidden, exiterr.Forbidden},
		{http.StatusNotFound, exiterr.NotFound},
		{http.StatusTooManyRequests, exiterr.RateLimit},
		{http.StatusInternalServerError, exiterr.API},
	}
	for _, c := range cases {
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			w.WriteHeader(c.status)
			_, _ = w.Write([]byte(`{"error":"nope"}`))
		}))
		_, err := New(srv.URL, testToken).Fleet().Status(context.Background())
		srv.Close()

		if err == nil {
			t.Fatalf("HTTP %d should have failed", c.status)
		}
		if got := exiterr.CodeOf(err); got != c.want {
			t.Errorf("HTTP %d: expected %v, got %v", c.status, c.want, got)
		}
	}
}

// A tool refusal is a 200 with isError set: the call reached the tool and it said
// no. The tool's own message must reach the user, not a generic transport error.
func TestToolLevelErrorIsReported(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text",` +
			`"text":"App not found: nope"}],"isError":true}}`))
	}))
	defer srv.Close()

	_, err := New(srv.URL, testToken).Fleet().Status(context.Background())
	if err == nil {
		t.Fatal("expected the tool error to surface")
	}
	if err.Error() != "App not found: nope" {
		t.Errorf("the server's own message must reach the user, got %q", err.Error())
	}
}

func TestMissingConfigFailsBeforeAnyRequest(t *testing.T) {
	_, err := New("", "tok").Fleet().Status(context.Background())
	if got := exiterr.CodeOf(err); got != exiterr.Usage {
		t.Errorf("no URL is a usage error, got %v", got)
	}

	_, err = New("https://example.test", "").Fleet().Status(context.Background())
	if got := exiterr.CodeOf(err); got != exiterr.Auth {
		t.Errorf("no token is an auth error, got %v", got)
	}
	if exiterr.HintOf(err) == "" {
		t.Error("a missing token must tell the user what to set")
	}
}

func TestUnreachableHostIsANetworkError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {}))
	url := srv.URL
	srv.Close() // nothing is listening now

	_, err := New(url, "t").Fleet().Status(context.Background())
	if got := exiterr.CodeOf(err); got != exiterr.Network {
		t.Errorf("expected a network error, got %v", got)
	}
}

// A breadcrumb hands you an id; a person types a name. The SDK must accept both
// and send the right field, because sending a name as server_id would 404.
func TestServerAcceptsAnIDOrAName(t *testing.T) {
	cases := []struct {
		reference string
		wantKey   string
		wantValue any
	}{
		{"6", "server_id", float64(6)},
		{"web-1", "server_name", "web-1"},
	}
	for _, c := range cases {
		var got rpcRequest
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			_ = json.NewDecoder(r.Body).Decode(&got)
			_, _ = w.Write([]byte(rpcOK(t, `{"id":6,"name":"web-1"}`)))
		}))

		if _, err := New(srv.URL, testToken).Fleet().Server(context.Background(), c.reference, false); err != nil {
			t.Fatalf("Server(%q) returned %v", c.reference, err)
		}
		srv.Close()

		if got.Params.Arguments[c.wantKey] != c.wantValue {
			t.Errorf("%q should send %s=%v, got input %+v", c.reference, c.wantKey, c.wantValue, got.Params.Arguments)
		}
		if _, unwanted := got.Params.Arguments["probe"]; unwanted {
			t.Errorf("probe must be absent unless asked for, got %+v", got.Params.Arguments)
		}
	}
}

func TestServerProbeIsOptIn(t *testing.T) {
	var got rpcRequest
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_ = json.NewDecoder(r.Body).Decode(&got)
		_, _ = w.Write([]byte(rpcOK(t, `{"id":6,"live":{"health":"ok"}}`)))
	}))
	defer srv.Close()

	detail, err := New(srv.URL, testToken).Fleet().Server(context.Background(), "6", true)
	if err != nil {
		t.Fatalf("Server returned %v", err)
	}
	if got.Params.Arguments["probe"] != true {
		t.Errorf("probe:true should be sent, got %+v", got.Params.Arguments)
	}
	if len(detail.Live) == 0 {
		t.Error("the live payload should survive as raw JSON")
	}
}

func TestServerDecodesTheStoredRecord(t *testing.T) {
	payload := `{"id":6,"name":"web-1","ip":"10.0.0.9","status":"online",` +
		`"edge":{"type":"kamal_proxy","detail":"v0.9.2"},` +
		`"metrics":{"cpu_percent":17,"cpu_cores":2,"disk":78,"load":0.29,"memory":"3.0 / 23 GB"},` +
		`"audit":{"last_status":"attention","last_at":"2026-09-11 05:17 UTC"},` +
		`"ssh":{"user":"deploy","port":22,"key":"a-key","configured":true},` +
		`"cron_jobs":[{"id":3,"name":"Sync","task":"x:sync","schedule":"every hour","enabled":true}],` +
		`"apps":[{"name":"kuickr","status":"running","domain":"kuickr.co"}]}`
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(rpcOK(t, payload)))
	}))
	defer srv.Close()

	d, err := New(srv.URL, testToken).Fleet().Server(context.Background(), "6", false)
	if err != nil {
		t.Fatalf("Server returned %v", err)
	}
	if d.Metrics.Disk != 78 || d.Metrics.CPUCores != 2 {
		t.Errorf("metrics decoded wrong: %+v", d.Metrics)
	}
	if d.Audit.LastStatus != "attention" {
		t.Errorf("the audit rollup must decode: %+v", d.Audit)
	}
	if !d.SSH.Configured || d.SSH.User != "deploy" || d.SSH.Key != "a-key" {
		t.Errorf("ssh decoded wrong: %+v", d.SSH)
	}
	if len(d.CronJobs) != 1 || len(d.Apps) != 1 {
		t.Errorf("cron jobs and apps must decode: %+v %+v", d.CronJobs, d.Apps)
	}
	if len(d.Live) != 0 {
		t.Error("live must be absent when not probed")
	}
}

// Defence in depth: every string the SERVER produced is rendered to stderr, so a
// token echoed back — by a proxy, a WAF, a misconfigured error page — would land
// in a terminal scrollback or a CI log. Each server-supplied path is covered.
func TestAServerEchoingTheTokenCannotLeakIt(t *testing.T) {
	const token = "Xy7f3c2a7e5b1d4a6c8e0f2b"

	cases := []struct {
		name   string
		status int
		body   string
	}{
		{"http error body", http.StatusForbidden,
			`{"error":"token ` + token + ` is not permitted"}`},
		{"json-rpc error", http.StatusOK,
			`{"jsonrpc":"2.0","id":1,"error":{"code":-32602,"message":"bad token ` + token + `"}}`},
		{"tool error", http.StatusOK,
			`{"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"refused for ` + token + `"}],"isError":true}}`},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				w.WriteHeader(c.status)
				_, _ = w.Write([]byte(c.body))
			}))
			defer srv.Close()

			_, err := New(srv.URL, token).Fleet().Status(context.Background())
			if err == nil {
				t.Fatal("expected an error")
			}
			if strings.Contains(err.Error(), token) {
				t.Errorf("the token survived into the error message: %q", err.Error())
			}
			if !strings.Contains(err.Error(), "[redacted]") {
				t.Errorf("expected the token to be replaced, got %q", err.Error())
			}
		})
	}
}

// A token echoed in a SUCCESSFUL result is still a leak — not to the server,
// which already has it, but to whatever reads the output: a scrollback, a CI
// log, a piped file.
func TestTheTokenIsRedactedFromSuccessfulPayloadsToo(t *testing.T) {
	const token = "Xy7f3c2a7e5b1d4a6c8e0f2b"
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(rpcOK(t, `[{"id":1,"name":"`+token+`"}]`)))
	}))
	defer srv.Close()

	servers, err := New(srv.URL, token).Fleet().Status(context.Background())
	if err != nil {
		t.Fatalf("Status returned %v", err)
	}
	if len(servers) != 1 {
		t.Fatalf("expected 1 server, got %d", len(servers))
	}
	if strings.Contains(servers[0].Name, token) {
		t.Errorf("the token survived into result data: %q", servers[0].Name)
	}
}

// A project you cloned should not be able to point the CLI at a host of its
// choosing, and a token must never travel in plaintext to one that is not local.
func TestRefusesToSendATokenOverPlaintextHTTP(t *testing.T) {
	_, err := New("http://evil.example.com", testToken).Fleet().Status(context.Background())
	if err == nil {
		t.Fatal("plaintext HTTP to a remote host must be refused")
	}
	if got := exiterr.CodeOf(err); got != exiterr.Usage {
		t.Errorf("expected a usage error, got %v", got)
	}
	if !strings.Contains(err.Error(), "plaintext") {
		t.Errorf("the reason should be plain, got %q", err.Error())
	}
}

// Loopback stays usable: that traffic never leaves the machine.
func TestPlaintextIsAllowedForLoopback(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(rpcOK(t, "[]")))
	}))
	defer srv.Close() // httptest serves http://127.0.0.1:port

	if _, err := New(srv.URL, testToken).Fleet().Status(context.Background()); err != nil {
		t.Errorf("loopback http must be allowed, got %v", err)
	}
}
