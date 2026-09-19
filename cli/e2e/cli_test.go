// Package e2e drives the REAL compiled binary against a stub Conductor.
//
// The unit tests prove each package; only this proves they are wired together —
// that PersistentPreRunE built the SDK from config, that the command reached it,
// and that the process exit code matches the failure.
package e2e

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// build compiles the binary once per run and returns its path.
func build(t *testing.T) string {
	t.Helper()
	bin := filepath.Join(t.TempDir(), "conductor")
	cmd := exec.Command("go", "build", "-o", bin, "../cmd/conductor")
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("could not build the binary: %v\n%s", err, out)
	}
	return bin
}

// run executes the binary with a clean environment plus whatever env is given,
// so a developer's real CONDUCTOR_URL cannot leak into a test.
func run(t *testing.T, bin string, env []string, args ...string) (string, string, int) {
	t.Helper()
	cmd := exec.Command(bin, args...)
	cmd.Env = append([]string{"HOME=" + t.TempDir(), "PATH=" + os.Getenv("PATH")}, env...)
	cmd.Dir = t.TempDir() // away from any .conductor.json in this repo

	var stdout, stderr strings.Builder
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	err := cmd.Run()

	code := 0
	var exitErr *exec.ExitError
	if err != nil {
		if ok := asExitError(err, &exitErr); ok {
			code = exitErr.ExitCode()
		} else {
			t.Fatalf("could not run the binary: %v", err)
		}
	}
	return stdout.String(), stderr.String(), code
}

func asExitError(err error, target **exec.ExitError) bool {
	if e, ok := err.(*exec.ExitError); ok {
		*target = e
		return true
	}
	return false
}

// stubConductor speaks the real transport: JSON-RPC over POST /mcp, with the
// tool payload as TEXT inside MCP's content envelope. A stub that accepted the
// CLI's own idea of the wire would let a wrong transport pass every e2e test.
func stubConductor(t *testing.T, status int, payload string) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/mcp" || r.Method != http.MethodPost {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		// Assert the WIRE, not just the route. Checking only method and path
		// would let a malformed JSON-RPC body, a missing bearer token or a
		// dropped protocol header pass every e2e test — the stub would be
		// agreeing with whatever the CLI sent.
		if got := r.Header.Get("Authorization"); got != "Bearer tok" && got != "Bearer bad" {
			t.Errorf("stub: expected a bearer token, got %q", got)
		}
		if got := r.Header.Get("MCP-Protocol-Version"); got == "" {
			t.Error("stub: the MCP-Protocol-Version header must be sent")
		}
		var body struct {
			JSONRPC string `json:"jsonrpc"`
			Method  string `json:"method"`
			Params  struct {
				Name      string         `json:"name"`
				Arguments map[string]any `json:"arguments"`
			} `json:"params"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Errorf("stub: body was not JSON: %v", err)
		}
		if body.JSONRPC != "2.0" || body.Method != "tools/call" {
			t.Errorf("stub: expected JSON-RPC tools/call, got jsonrpc=%q method=%q", body.JSONRPC, body.Method)
		}
		if body.Params.Name == "" || body.Params.Arguments["action"] == nil {
			t.Errorf("stub: expected a tool name and an action argument, got %+v", body.Params)
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		if status != http.StatusOK {
			_, _ = w.Write([]byte(payload)) // an error body, sent as-is
			return
		}
		encoded, err := json.Marshal(payload)
		if err != nil {
			t.Fatalf("could not encode the payload: %v", err)
		}
		_, _ = w.Write([]byte(`{"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":` +
			string(encoded) + `}],"isError":false}}`))
	}))
	t.Cleanup(srv.Close)
	return srv
}

func TestFleetRendersTheEnvelopeEndToEnd(t *testing.T) {
	bin := build(t)
	srv := stubConductor(t, 200, `[{"id":4,"name":"web-1","ip":"10.0.0.1","status":"online","cpu_percent":4,"disk":29,"memory":"4.0 / 63 GB","uptime":"1d","edge":{"type":"kamal_proxy"},"apps":[{"name":"kuickr","status":"running"}]}]`)

	stdout, stderr, code := run(t, bin, []string{
		"CONDUCTOR_URL=" + srv.URL, "CONDUCTOR_MCP_TOKEN=tok",
	}, "fleet", "--json")

	if code != 0 {
		t.Fatalf("expected exit 0, got %d (stderr: %s)", code, stderr)
	}

	var env struct {
		OK          bool                          `json:"ok"`
		Data        []struct{ Name, Edge string } `json:"data"`
		Summary     string                        `json:"summary"`
		Breadcrumbs []struct{ Command string }    `json:"breadcrumbs"`
	}
	if err := json.Unmarshal([]byte(stdout), &env); err != nil {
		t.Fatalf("stdout was not the JSON envelope: %v\n%s", err, stdout)
	}
	if !env.OK || len(env.Data) != 1 || env.Data[0].Name != "web-1" {
		t.Errorf("unexpected envelope: %+v", env)
	}
	if env.Data[0].Edge != "kamal_proxy" {
		t.Errorf("the edge must be reported per server, got %q", env.Data[0].Edge)
	}
	if len(env.Breadcrumbs) == 0 {
		t.Error("every success must carry breadcrumbs")
	}
	if !strings.Contains(env.Summary, "all online and running") {
		t.Errorf("summary should lead with health, got %q", env.Summary)
	}
}

func TestJQFlagFiltersRealOutput(t *testing.T) {
	bin := build(t)
	srv := stubConductor(t, 200, `[{"id":4,"name":"web-1","status":"online"}]`)

	stdout, _, code := run(t, bin, []string{
		"CONDUCTOR_URL=" + srv.URL, "CONDUCTOR_MCP_TOKEN=tok",
	}, "fleet", "--jq", ".data[].name")

	if code != 0 {
		t.Fatalf("expected exit 0, got %d", code)
	}
	if strings.TrimSpace(stdout) != "web-1" {
		t.Errorf("expected the filtered name, got %q", stdout)
	}
}

// The exit code is the contract a script branches on.
func TestUnauthorizedExitsThree(t *testing.T) {
	bin := build(t)
	srv := stubConductor(t, http.StatusUnauthorized, `{"error":"invalid token"}`)

	stdout, stderr, code := run(t, bin, []string{
		"CONDUCTOR_URL=" + srv.URL, "CONDUCTOR_MCP_TOKEN=bad",
	}, "fleet", "--json")

	if code != 3 {
		t.Fatalf("a 401 must exit 3, got %d", code)
	}
	if stdout != "" {
		t.Errorf("errors belong on stderr, stdout had %q", stdout)
	}
	var got struct {
		OK                bool
		Error, Code, Hint string
	}
	if err := json.Unmarshal([]byte(stderr), &got); err != nil {
		t.Fatalf("the error must be structured JSON, not help text: %v\n%s", err, stderr)
	}
	if got.OK || got.Code != "auth" || got.Hint == "" {
		t.Errorf("unexpected error envelope: %+v", got)
	}
}

// Without a token the CLI must fail before making any request at all.
func TestMissingTokenExitsThreeWithoutCallingTheServer(t *testing.T) {
	bin := build(t)
	called := false
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		called = true
		_, _ = w.Write([]byte(`{"result":[]}`))
	}))
	defer srv.Close()

	_, stderr, code := run(t, bin, []string{"CONDUCTOR_URL=" + srv.URL}, "fleet", "--json")

	if code != 3 {
		t.Fatalf("a missing token must exit 3, got %d (stderr: %s)", code, stderr)
	}
	if called {
		t.Error("the CLI must not send a request it knows will fail")
	}
}

func TestContradictoryFormatFlagsAreAUsageError(t *testing.T) {
	bin := build(t)
	_, stderr, code := run(t, bin, nil, "fleet", "--json", "--markdown")
	if code != 2 {
		t.Fatalf("contradictory flags must exit 2, got %d (stderr: %s)", code, stderr)
	}
}

func TestVersionWorksWithoutAnyConfiguration(t *testing.T) {
	bin := build(t)
	stdout, stderr, code := run(t, bin, nil, "version", "--json")
	if code != 0 {
		t.Fatalf("version must not need config, got %d (stderr: %s)", code, stderr)
	}
	if !strings.Contains(stdout, "version") {
		t.Errorf("expected a version envelope, got %q", stdout)
	}
}

// The token must never be reconstructible from output. This drives the real
// binary because that is the only place the whole rendering path is exercised.
func TestAuthStatusReportsTheSourceWithoutLeakingTheToken(t *testing.T) {
	bin := build(t)
	// Deliberately shares no prefix with "conductor": the binary name appears all
	// over legitimate output, so a token starting with it would trip the
	// substring scan below for reasons that have nothing to do with leaking.
	secret := "Xy7f3c2a7e5b1d4a6c8e0f2b"

	stdout, stderr, code := run(t, bin, []string{
		"CONDUCTOR_URL=https://c.test", "CONDUCTOR_MCP_TOKEN=" + secret,
	}, "auth", "status", "--json")

	if code != 0 {
		t.Fatalf("expected exit 0, got %d (stderr: %s)", code, stderr)
	}
	// Checking only for the WHOLE token is too weak: a fingerprint that revealed
	// all but the last character would pass. Assert that no long run of the
	// token's characters survives, and that its middle never appears at all.
	combined := stdout + stderr
	if strings.Contains(combined, secret) {
		t.Fatal("the whole token appeared in output")
	}
	middle := secret[4 : len(secret)-4]
	if strings.Contains(combined, middle) {
		t.Fatalf("the token's middle leaked: %q", middle)
	}
	for size := 6; size <= len(secret); size++ {
		for i := 0; i+size <= len(secret); i++ {
			if run := secret[i : i+size]; strings.Contains(combined, run) {
				t.Fatalf("a %d-character run of the token leaked: %q", size, run)
			}
		}
	}
	if !strings.Contains(stdout, "env CONDUCTOR_MCP_TOKEN") {
		t.Errorf("the source should be reported, got %q", stdout)
	}
}

// Login reads stdin. Nothing is written anywhere when there is nothing to read,
// so this never reaches the real keyring.
func TestAuthLoginWithoutStdinIsAUsageError(t *testing.T) {
	bin := build(t)
	_, stderr, code := run(t, bin, []string{"CONDUCTOR_URL=https://c.test"}, "auth", "login")

	if code != 2 {
		t.Fatalf("an empty token must exit 2, got %d (stderr: %s)", code, stderr)
	}
	if !strings.Contains(stderr, "conductor auth login") {
		t.Errorf("the hint should show how to pipe a token, got %q", stderr)
	}
}

// There must be no --token flag: an argument lands in `ps`, shell history and
// an agent transcript. This asserts the absence deliberately.
func TestThereIsNoTokenFlag(t *testing.T) {
	bin := build(t)
	stdout, stderr, _ := run(t, bin, nil, "auth", "login", "--help")
	if strings.Contains(stdout+stderr, "--token") {
		t.Error("a --token flag would put the secret back into argv")
	}
}

// Whether the keyring is consulted is asserted properly in
// internal/cli.TestCommandsAnnotatedAuthSkipNeverReadTheKeyring, which
// instruments the store. This only checks the user-visible outcome: version
// works with a URL configured and no token.
func TestVersionWorksWithAUrlAndNoToken(t *testing.T) {
	bin := build(t)
	_, stderr, code := run(t, bin, []string{"CONDUCTOR_URL=https://c.test"}, "version", "--json")
	if code != 0 {
		t.Fatalf("version must not depend on auth, got %d (stderr: %s)", code, stderr)
	}
}

func TestServerRendersDetailAndWarnsTheDataIsStored(t *testing.T) {
	bin := build(t)
	srv := stubConductor(t, 200, `{"id":6,"name":"web-1","ip":"10.0.0.9","status":"online","edge":{"type":"kamal_proxy","detail":"v0.9.2"},"metrics":{"cpu_percent":17,"cpu_cores":2,"disk":78,"load":0.29,"memory":"3.0 / 23 GB"},"audit":{"last_status":"attention","last_at":"2026-09-11 05:17 UTC"},"ssh":{"user":"deploy","port":22,"key":"a-key","configured":true},"apps":[{"name":"kuickr","status":"running","domain":"kuickr.co"}]}`)

	stdout, stderr, code := run(t, bin, []string{
		"CONDUCTOR_URL=" + srv.URL, "CONDUCTOR_MCP_TOKEN=tok",
	}, "server", "show", "6", "--json")

	if code != 0 {
		t.Fatalf("expected exit 0, got %d (stderr: %s)", code, stderr)
	}

	var env struct {
		OK   bool `json:"ok"`
		Data struct {
			Name, Edge, SSH, Audit string
			Apps                   []string
		} `json:"data"`
		Summary string `json:"summary"`
		Notice  string `json:"notice"`
	}
	if err := json.Unmarshal([]byte(stdout), &env); err != nil {
		t.Fatalf("stdout was not the envelope: %v\n%s", err, stdout)
	}
	if env.Data.Name != "web-1" || !strings.Contains(env.Data.Edge, "kamal_proxy") {
		t.Errorf("unexpected detail: %+v", env.Data)
	}
	// The audit says "attention", so the summary must lead with that rather than
	// burying it under a wall of healthy-looking fields.
	if !strings.Contains(env.Summary, "attention") {
		t.Errorf("the summary should surface the audit concern, got %q", env.Summary)
	}
	// Stored data presented as current is how someone acts on a stale picture.
	if !strings.Contains(env.Notice, "--probe") {
		t.Errorf("the notice must say the data is stored, got %q", env.Notice)
	}
	if !strings.Contains(env.Data.SSH, "a-key") || strings.Contains(stdout, "PRIVATE KEY") {
		t.Errorf("ssh should name the key, never carry one: %q", env.Data.SSH)
	}
}

func TestServerAcceptsANameNotJustAnID(t *testing.T) {
	bin := build(t)
	srv := stubConductor(t, 200, `{"id":6,"name":"web-1","status":"online"}`)

	stdout, _, code := run(t, bin, []string{
		"CONDUCTOR_URL=" + srv.URL, "CONDUCTOR_MCP_TOKEN=tok",
	}, "server", "show", "web-1", "--jq", ".data.name")

	if code != 0 {
		t.Fatalf("expected exit 0, got %d", code)
	}
	if strings.TrimSpace(stdout) != "web-1" {
		t.Errorf("expected the named server, got %q", stdout)
	}
}

func TestServerRequiresExactlyOneArgument(t *testing.T) {
	bin := build(t)
	for _, args := range [][]string{{"server", "show"}, {"server", "show", "a", "b"}} {
		_, stderr, code := run(t, bin, []string{
			"CONDUCTOR_URL=https://c.test", "CONDUCTOR_MCP_TOKEN=tok",
		}, args...)
		if code != 2 {
			t.Errorf("%v should exit 2, got %d (stderr: %s)", args, code, stderr)
		}
	}
}

// A 404 must reach the operator as "not found", not as a generic failure.
func TestServerNotFoundExitsFour(t *testing.T) {
	bin := build(t)
	srv := stubConductor(t, http.StatusNotFound, `{"error":"Server not found: 99"}`)

	_, stderr, code := run(t, bin, []string{
		"CONDUCTOR_URL=" + srv.URL, "CONDUCTOR_MCP_TOKEN=tok",
	}, "server", "show", "99", "--json")

	if code != 4 {
		t.Fatalf("a 404 must exit 4, got %d (stderr: %s)", code, stderr)
	}
	if !strings.Contains(stderr, "Server not found") {
		t.Errorf("the server's own message should reach the user, got %q", stderr)
	}
}
