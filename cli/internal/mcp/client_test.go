package mcp

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/nauman/rails-conductor/cli/internal/exiterr"
)

func TestCallSendsToolNameAndBearerToken(t *testing.T) {
	var gotAuth, gotPath string
	var gotBody toolRequest

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotAuth, gotPath = r.Header.Get("Authorization"), r.URL.Path
		_ = json.NewDecoder(r.Body).Decode(&gotBody)
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"result":[]}`))
	}))
	defer srv.Close()

	if _, err := New(srv.URL, "tok_abc").Fleet().Status(context.Background()); err != nil {
		t.Fatalf("Status returned %v", err)
	}
	if gotAuth != "Bearer tok_abc" {
		t.Errorf("expected a bearer token, got %q", gotAuth)
	}
	if gotPath != "/mcp/call" {
		t.Errorf("expected /mcp/call, got %q", gotPath)
	}
	if gotBody.Name != "conductor_read" || gotBody.Input["action"] != "fleet_status" {
		t.Errorf("wrong tool call: %+v", gotBody)
	}
}

func TestStatusDecodesServers(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{"result":[{"id":4,"name":"box","status":"online",
			"cpu_percent":7,"disk":29,"edge":{"type":"kamal_proxy"},
			"apps":[{"name":"kuickr","status":"running"}]}]}`))
	}))
	defer srv.Close()

	servers, err := New(srv.URL, "t").Fleet().Status(context.Background())
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
		_, err := New(srv.URL, "t").Fleet().Status(context.Background())
		srv.Close()

		if err == nil {
			t.Fatalf("HTTP %d should have failed", c.status)
		}
		if got := exiterr.CodeOf(err); got != c.want {
			t.Errorf("HTTP %d: expected %v, got %v", c.status, c.want, got)
		}
	}
}

// A tool refusal is a 200 with an error body: the call worked, the tool said no.
func TestToolLevelErrorIsReported(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{"error":"App not found: nope"}`))
	}))
	defer srv.Close()

	_, err := New(srv.URL, "t").Fleet().Status(context.Background())
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
		var got toolRequest
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			_ = json.NewDecoder(r.Body).Decode(&got)
			_, _ = w.Write([]byte(`{"result":{"id":6,"name":"web-1"}}`))
		}))

		if _, err := New(srv.URL, "t").Fleet().Server(context.Background(), c.reference, false); err != nil {
			t.Fatalf("Server(%q) returned %v", c.reference, err)
		}
		srv.Close()

		if got.Input[c.wantKey] != c.wantValue {
			t.Errorf("%q should send %s=%v, got input %+v", c.reference, c.wantKey, c.wantValue, got.Input)
		}
		if _, unwanted := got.Input["probe"]; unwanted {
			t.Errorf("probe must be absent unless asked for, got %+v", got.Input)
		}
	}
}

func TestServerProbeIsOptIn(t *testing.T) {
	var got toolRequest
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_ = json.NewDecoder(r.Body).Decode(&got)
		_, _ = w.Write([]byte(`{"result":{"id":6,"live":{"health":"ok"}}}`))
	}))
	defer srv.Close()

	detail, err := New(srv.URL, "t").Fleet().Server(context.Background(), "6", true)
	if err != nil {
		t.Fatalf("Server returned %v", err)
	}
	if got.Input["probe"] != true {
		t.Errorf("probe:true should be sent, got %+v", got.Input)
	}
	if len(detail.Live) == 0 {
		t.Error("the live payload should survive as raw JSON")
	}
}

func TestServerDecodesTheStoredRecord(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{"result":{"id":6,"name":"web-1","ip":"10.0.0.9","status":"online",
			"edge":{"type":"kamal_proxy","detail":"v0.9.2"},
			"metrics":{"cpu_percent":17,"cpu_cores":2,"disk":78,"load":0.29,"memory":"3.0 / 23 GB"},
			"audit":{"last_status":"attention","last_at":"2026-09-11 05:17 UTC"},
			"ssh":{"user":"deploy","port":22,"key":"a-key","configured":true},
			"cron_jobs":[{"id":3,"name":"Sync","task":"x:sync","schedule":"every hour","enabled":true}],
			"apps":[{"name":"kuickr","status":"running","domain":"kuickr.co"}]}}`))
	}))
	defer srv.Close()

	d, err := New(srv.URL, "t").Fleet().Server(context.Background(), "6", false)
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
