package cli

import (
	"bytes"
	"context"
	"os"
	"testing"
)

// countingStore records whether the keyring was consulted at all.
type countingStore struct{ gets int }

func (c *countingStore) Get(string) (string, error) { c.gets++; return "", nil }
func (c *countingStore) Set(string, string) error   { return nil }
func (c *countingStore) Delete(string) error        { return nil }

// A locked keychain must not be able to break a command that needs no token.
// The previous version of this test ran `version` and asserted exit 0, which
// would have passed while the keyring was being read on every invocation — it
// proved nothing about the thing it was named for.
func TestCommandsAnnotatedAuthSkipNeverReadTheKeyring(t *testing.T) {
	t.Setenv("CONDUCTOR_URL", "https://c.test")
	t.Setenv("CONDUCTOR_MCP_TOKEN", "") // force the keyring path for anything not skipping

	store := &countingStore{}
	root, _ := NewRootCmd(os.Stdout, os.Stderr, store)
	root.SetOut(&bytes.Buffer{})
	root.SetErr(&bytes.Buffer{})
	root.SetArgs([]string{"version", "--json"})

	if err := root.ExecuteContext(context.Background()); err != nil {
		t.Fatalf("version returned %v", err)
	}
	if store.gets != 0 {
		t.Errorf("version consulted the keyring %d time(s) — it is annotated auth:skip", store.gets)
	}
}

// The counterpart: a command that DOES need a token must consult the store, or
// the test above would pass simply because resolution never happens anywhere.
func TestCommandsWithoutTheAnnotationDoReadTheKeyring(t *testing.T) {
	t.Setenv("CONDUCTOR_URL", "https://c.test")
	t.Setenv("CONDUCTOR_MCP_TOKEN", "")

	store := &countingStore{}
	root, _ := NewRootCmd(os.Stdout, os.Stderr, store)
	root.SetOut(&bytes.Buffer{})
	root.SetErr(&bytes.Buffer{})
	root.SetArgs([]string{"auth", "status", "--json"})

	_ = root.ExecuteContext(context.Background())
	if store.gets == 0 {
		t.Error("auth status must consult the keyring; if it does not, the skip test proves nothing")
	}
}
