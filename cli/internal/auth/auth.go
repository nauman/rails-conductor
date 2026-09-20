// Package auth stores and resolves the Conductor token.
//
// The token never travels in argv. That is not a style preference: an argument
// is visible in `ps`, lands in shell history, and — when an agent runs the
// command — is written into a transcript that outlives the session. It is the
// reason the Ruby shim bin/conductor exists at all, and this package is what
// makes that workaround unnecessary rather than permanent.
//
// Resolution order is env > keyring. A flag is deliberately absent: there is no
// --token, because offering one would put the value straight back into argv.
package auth

import (
	"errors"
	"fmt"
	"os"
	"strings"

	"github.com/nauman/rails-conductor/cli/internal/exiterr"
	"github.com/zalando/go-keyring"
)

// service is the keyring service name. The account is the Conductor base URL,
// so one machine can hold tokens for several instances without collision.
const service = "conductor-cli"

// Source says where a token came from, for `auth status` and --verbose. It
// never carries the token itself.
type Source string

const (
	SourceNone    Source = "none"
	SourceEnv     Source = "env CONDUCTOR_MCP_TOKEN"
	SourceKeyring Source = "keyring"
)

// Store is the keyring-backed token store. It is an interface so tests do not
// touch the real OS keychain — a unit test that prompts for a login password
// is a test nobody runs.
type Store interface {
	Get(account string) (string, error)
	Set(account, token string) error
	Delete(account string) error
}

// SystemStore uses the OS keychain: Keychain on macOS, libsecret on Linux,
// Credential Manager on Windows.
type SystemStore struct{}

func (SystemStore) Get(account string) (string, error) {
	token, err := keyring.Get(service, account)
	if errors.Is(err, keyring.ErrNotFound) {
		return "", nil
	}
	return token, err
}

func (SystemStore) Set(account, token string) error { return keyring.Set(service, account, token) }

func (SystemStore) Delete(account string) error {
	err := keyring.Delete(service, account)
	if errors.Is(err, keyring.ErrNotFound) {
		return nil // deleting what is not there is success, not an error
	}
	return err
}

// Resolve returns the token and where it came from. The environment wins so a
// CI job or a one-off override needs no keyring at all.
//
// A keyring read that FAILS is not the same as a keyring that is empty: the
// first is reported, the second is simply "no token". Swallowing the difference
// is how a locked keychain gets misreported as "please log in", sending the
// user to re-enter a token they already have.
func Resolve(store Store, apiURL string) (token string, source Source, err error) {
	if v := strings.TrimSpace(os.Getenv("CONDUCTOR_MCP_TOKEN")); v != "" {
		return v, SourceEnv, nil
	}
	if store == nil || apiURL == "" {
		return "", SourceNone, nil
	}

	stored, err := store.Get(apiURL)
	if err != nil {
		return "", SourceNone, exiterr.Wrap(exiterr.Auth, err,
			fmt.Sprintf("could not read the keyring for %s", apiURL),
			"Unlock your keychain, or set CONDUCTOR_MCP_TOKEN to bypass it.")
	}
	if stored == "" {
		return "", SourceNone, nil
	}
	return stored, SourceKeyring, nil
}

// Save stores a token against an instance URL.
func Save(store Store, apiURL, token string) error {
	if strings.TrimSpace(token) == "" {
		return exiterr.New(exiterr.Usage, "refusing to store an empty token",
			"Pipe the token in: printf %s \"$TOKEN\" | conductor auth login")
	}
	if apiURL == "" {
		return exiterr.New(exiterr.Usage, "no Conductor URL to store the token against",
			"Set CONDUCTOR_URL, or pass --api-url.")
	}
	if err := store.Set(apiURL, token); err != nil {
		return exiterr.Wrap(exiterr.Auth, err, "could not write to the keyring",
			"Unlock your keychain and try again.")
	}
	return nil
}

// Forget removes a stored token.
func Forget(store Store, apiURL string) error {
	if apiURL == "" {
		return exiterr.New(exiterr.Usage, "no Conductor URL to forget a token for",
			"Set CONDUCTOR_URL, or pass --api-url.")
	}
	if err := store.Delete(apiURL); err != nil {
		return exiterr.Wrap(exiterr.Auth, err, "could not remove the token from the keyring", "")
	}
	return nil
}

// Fingerprint renders a token safely for display: enough to tell two tokens
// apart, never enough to use one. Short values show as fully masked rather than
// leaking most of themselves.
func Fingerprint(token string) string {
	if token == "" {
		return ""
	}
	if len(token) <= 8 {
		return strings.Repeat("•", len(token))
	}
	return token[:3] + strings.Repeat("•", 6) + token[len(token)-2:]
}
