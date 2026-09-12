// Package config resolves settings by layer: flags > env > project file >
// global file > defaults.
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
	Token   string
	Profile string

	// Sources maps a field name to the layer that set it.
	Sources map[string]string
}

// file is the on-disk shape of .conductor.json, at either scope.
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
		cfg.applyFile(filepath.Join(home, ".conductor.json"), "global file")
	}

	// Layer 3: nearest project file, walking up from the working directory.
	if path := findProjectFile(startDir); path != "" {
		cfg.applyFile(path, "project file")
	}

	// Layer 2: environment.
	if v := strings.TrimSpace(os.Getenv("CONDUCTOR_URL")); v != "" {
		cfg.APIURL, cfg.Sources["api_url"] = v, "env CONDUCTOR_URL"
	}
	if v := strings.TrimSpace(os.Getenv("CONDUCTOR_MCP_TOKEN")); v != "" {
		// The token is never written to a config file by this CLI; it comes
		// from the environment or, later, the keyring.
		cfg.Token, cfg.Sources["token"] = v, "env CONDUCTOR_MCP_TOKEN"
	}
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

func (c *Config) applyFile(path, source string) {
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
	if parsed.APIURL != "" {
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
