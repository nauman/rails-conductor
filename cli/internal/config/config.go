// Package config resolves settings by layer: flags > env > global file >
// defaults.
//
// A PROJECT file may not set api_url, and that is a security boundary rather
// than a simplification. `.conductor.json` is discovered by walking up from the
// working directory, so it is attacker-supplied the moment you run the CLI
// inside a repository you cloned. If such a file could set api_url, cloning a
// hostile repo and running `conductor` in it would send CONDUCTOR_MCP_TOKEN to
// whatever host that file named.
//
// The keyring is not exposed this way — tokens are stored per instance URL, so
// an unknown URL finds no token — but an exported environment token is sent
// wherever the CLI is pointed. Project files therefore carry only settings that
// cannot redirect a credential.
//
// Sources records which layer supplied each value. That is not bookkeeping for
// its own sake — when a CLI reads the wrong URL, the only useful question is
// "where did that come from", and without this the answer is a guess.
//
// Profiles and keyring-backed tokens are a later slice; this layer is shaped to
// take them without moving the callers.
package config

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
)

// Config is the resolved settings for one invocation.
type Config struct {
	APIURL  string
	Profile string

	// Sources maps a field name to the layer that set it.
	Sources map[string]string
}

// file is the on-disk shape of .conductor.json. api_url is honored only from the
// GLOBAL file; see the package comment.
type file struct {
	APIURL  string `json:"api_url"`
	Profile string `json:"profile"`
}

// Load resolves configuration. Flag values are applied by the caller AFTER this
// returns, so an explicit flag always wins over every file and variable.
func Load(startDir string) *Config {
	cfg := &Config{Sources: map[string]string{}}

	// Layer 4: global file.
	if home, err := os.UserHomeDir(); err == nil {
		cfg.applyFile(filepath.Join(home, ".conductor.json"), "global file", withAPIURL)
	}

	// Layer 3: nearest project file, walking up from the working directory.
	// Settings only — never api_url. A project file is whatever the directory
	// you happen to be standing in says it is.
	if path := findProjectFile(startDir); path != "" {
		cfg.applyFile(path, "project file", withoutAPIURL)
	}

	// Layer 2: environment.
	if v := strings.TrimSpace(os.Getenv("CONDUCTOR_URL")); v != "" {
		cfg.APIURL, cfg.Sources["api_url"] = v, "env CONDUCTOR_URL"
	}
	// The token is deliberately NOT resolved here. It lives in internal/auth,
	// which reads the environment then the keyring, so there is exactly one
	// place that answers "which token" and one place that can leak it.
	if v := strings.TrimSpace(os.Getenv("CONDUCTOR_PROFILE")); v != "" {
		cfg.Profile, cfg.Sources["profile"] = v, "env CONDUCTOR_PROFILE"
	}

	return cfg
}

// SetAPIURL applies an explicit flag, recording that it won.
func (c *Config) SetAPIURL(v string) {
	if strings.TrimSpace(v) == "" {
		return
	}
	c.APIURL, c.Sources["api_url"] = v, "flag --api-url"
}

// SetProfile applies an explicit --profile.
func (c *Config) SetProfile(v string) {
	if strings.TrimSpace(v) == "" {
		return
	}
	c.Profile, c.Sources["profile"] = v, "flag --profile"
}

// Whether a config layer is trusted to name the host a token is sent to.
type apiURLTrust bool

const (
	withAPIURL    apiURLTrust = true
	withoutAPIURL apiURLTrust = false
)

func (c *Config) applyFile(path, source string, trust apiURLTrust) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return
	}
	var parsed file
	// A malformed config file is ignored rather than fatal: it must not make
	// every command unusable, and --verbose shows which layer applied.
	if err := json.Unmarshal(raw, &parsed); err != nil {
		return
	}
	if parsed.APIURL != "" && trust == withAPIURL {
		c.APIURL, c.Sources["api_url"] = parsed.APIURL, source
	}
	if parsed.Profile != "" {
		c.Profile, c.Sources["profile"] = parsed.Profile, source
	}
}

// findProjectFile walks up from dir looking for .conductor.json, stopping at
// the filesystem root.
func findProjectFile(dir string) string {
	if dir == "" {
		return ""
	}
	current, err := filepath.Abs(dir)
	if err != nil {
		return ""
	}
	for {
		candidate := filepath.Join(current, ".conductor.json")
		if info, err := os.Stat(candidate); err == nil && !info.IsDir() {
			return candidate
		}
		parent := filepath.Dir(current)
		if parent == current {
			return ""
		}
		current = parent
	}
}
