package auth

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/nauman/rails-conductor/cli/internal/exiterr"
)

// fakeStore keeps unit tests away from the real OS keychain — a test that
// prompts for a login password is a test nobody runs.
type fakeStore struct {
	items  map[string]string
	getErr error
	setErr error
}

func newFakeStore() *fakeStore { return &fakeStore{items: map[string]string{}} }

func (f *fakeStore) Get(account string) (string, error) {
	if f.getErr != nil {
		return "", f.getErr
	}
	return f.items[account], nil
}

func (f *fakeStore) Set(account, token string) error {
	if f.setErr != nil {
		return f.setErr
	}
	f.items[account] = token
	return nil
}

func (f *fakeStore) Delete(account string) error {
	delete(f.items, account)
	return nil
}

func TestEnvironmentBeatsKeyring(t *testing.T) {
	store := newFakeStore()
	_ = store.Set("https://c.test", "from_keyring")
	t.Setenv("CONDUCTOR_MCP_TOKEN", "from_env")

	token, source, err := Resolve(store, "https://c.test")
	if err != nil {
		t.Fatalf("Resolve returned %v", err)
	}
	if token != "from_env" || source != SourceEnv {
		t.Errorf("env must win: got %q from %q", token, source)
	}
}

func TestKeyringUsedWhenNoEnvironmentToken(t *testing.T) {
	store := newFakeStore()
	_ = store.Set("https://c.test", "from_keyring")
	t.Setenv("CONDUCTOR_MCP_TOKEN", "")

	token, source, err := Resolve(store, "https://c.test")
	if err != nil {
		t.Fatalf("Resolve returned %v", err)
	}
	if token != "from_keyring" || source != SourceKeyring {
		t.Errorf("expected the keyring token, got %q from %q", token, source)
	}
}

// Tokens are stored per instance URL, so two Conductors on one machine do not
// hand each other's token out.
func TestTokensAreScopedPerInstance(t *testing.T) {
	store := newFakeStore()
	t.Setenv("CONDUCTOR_MCP_TOKEN", "")
	if err := Save(store, "https://a.test", "token_a"); err != nil {
		t.Fatal(err)
	}
	if err := Save(store, "https://b.test", "token_b"); err != nil {
		t.Fatal(err)
	}

	a, _, _ := Resolve(store, "https://a.test")
	b, _, _ := Resolve(store, "https://b.test")
	if a != "token_a" || b != "token_b" {
		t.Errorf("tokens crossed instances: a=%q b=%q", a, b)
	}

	other, source, _ := Resolve(store, "https://c.test")
	if other != "" || source != SourceNone {
		t.Errorf("an unknown instance must have no token, got %q from %q", other, source)
	}
}

// A locked keychain must not be reported as "no token" — that sends the user to
// re-enter a token they already have.
func TestAKeyringFailureIsReportedNotSwallowed(t *testing.T) {
	store := newFakeStore()
	store.getErr = errors.New("keychain is locked")
	t.Setenv("CONDUCTOR_MCP_TOKEN", "")

	_, source, err := Resolve(store, "https://c.test")
	if err == nil {
		t.Fatal("a keyring read failure must surface")
	}
	if source != SourceNone {
		t.Errorf("a failed read has no source, got %q", source)
	}
	if got := exiterr.CodeOf(err); got != exiterr.Auth {
		t.Errorf("expected an auth exit code, got %v", got)
	}
	if !strings.Contains(exiterr.HintOf(err), "CONDUCTOR_MCP_TOKEN") {
		t.Errorf("the hint should offer the bypass, got %q", exiterr.HintOf(err))
	}
}

func TestEmptyKeyringIsNotAnError(t *testing.T) {
	t.Setenv("CONDUCTOR_MCP_TOKEN", "")
	token, source, err := Resolve(newFakeStore(), "https://c.test")
	if err != nil {
		t.Fatalf("an empty keyring is not a failure: %v", err)
	}
	if token != "" || source != SourceNone {
		t.Errorf("expected no token, got %q from %q", token, source)
	}
}

func TestRefusesToStoreAnEmptyToken(t *testing.T) {
	err := Save(newFakeStore(), "https://c.test", "   ")
	if got := exiterr.CodeOf(err); got != exiterr.Usage {
		t.Errorf("expected a usage error, got %v", got)
	}
}

func TestForgetIsIdempotent(t *testing.T) {
	store := newFakeStore()
	if err := Forget(store, "https://never-stored.test"); err != nil {
		t.Errorf("forgetting an absent token must succeed, got %v", err)
	}
}

// The fingerprint exists to identify a token, never to reconstruct one.
func TestFingerprintNeverRevealsTheToken(t *testing.T) {
	secret := "conductor_pat_9f3c2a7e5b1d"
	got := Fingerprint(secret)

	if strings.Contains(got, "9f3c2a7e5b1d") {
		t.Errorf("the fingerprint leaked the token body: %q", got)
	}
	if len(got) >= len(secret) {
		t.Errorf("the fingerprint should be shorter than the token, got %q", got)
	}
	if Fingerprint("") != "" {
		t.Error("no token means no fingerprint")
	}
	// A short token must be fully masked rather than mostly shown.
	if short := Fingerprint("abcd"); strings.Contains(short, "a") {
		t.Errorf("a short token must be fully masked, got %q", short)
	}
}

// The invariant that moved here from config: nothing on disk may supply a token
// except the keyring itself.
func TestAConfigFileCannotSupplyAToken(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, ".conductor.json"),
		[]byte(`{"api_url":"https://x.test","token":"leaked_from_file"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("CONDUCTOR_MCP_TOKEN", "")

	// Resolve consults only the environment and the keyring; a file on disk is
	// not one of its inputs, whatever it claims to contain.
	token, source, err := Resolve(newFakeStore(), "https://x.test")
	if err != nil {
		t.Fatal(err)
	}
	if token != "" || source != SourceNone {
		t.Errorf("a config file must never supply a token, got %q from %q", token, source)
	}
}
