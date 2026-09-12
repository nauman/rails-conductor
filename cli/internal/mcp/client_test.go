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
