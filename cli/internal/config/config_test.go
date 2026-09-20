package config

import (
	"os"
	"path/filepath"
	"testing"
)

func TestPrecedenceFlagsBeatEnvBeatsFiles(t *testing.T) {
	home := t.TempDir()
	if err := os.WriteFile(filepath.Join(home, ".conductor.json"),
		[]byte(`{"api_url":"https://from-global.test"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("HOME", home)

	// Global file alone.
	t.Setenv("CONDUCTOR_URL", "")
	cfg := Load(t.TempDir())
	if cfg.APIURL != "https://from-global.test" {
		t.Errorf("the global file should apply, got %q", cfg.APIURL)
	}

	// Env beats the file.
	t.Setenv("CONDUCTOR_URL", "https://from-env.test")
	cfg = Load(t.TempDir())
	if cfg.APIURL != "https://from-env.test" {
		t.Errorf("env must beat the global file, got %q", cfg.APIURL)
	}
	if cfg.Sources["api_url"] != "env CONDUCTOR_URL" {
		t.Errorf("the source must be recorded, got %q", cfg.Sources["api_url"])
	}

	// An explicit flag beats everything.
	cfg.SetAPIURL("https://from-flag.test")
	if cfg.APIURL != "https://from-flag.test" {
		t.Errorf("a flag must win, got %q", cfg.APIURL)
	}
	if cfg.Sources["api_url"] != "flag --api-url" {
		t.Errorf("the flag source must be recorded, got %q", cfg.Sources["api_url"])
	}
}

// Project files are still discovered by walking up — they just cannot carry
// api_url. Asserted on `profile`, which they may set.
func TestProjectFileIsFoundByWalkingUp(t *testing.T) {
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, ".conductor.json"),
		[]byte(`{"profile":"walked-up"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	nested := filepath.Join(root, "a", "b", "c")
	if err := os.MkdirAll(nested, 0o755); err != nil {
		t.Fatal(err)
	}

	t.Setenv("CONDUCTOR_PROFILE", "")
	if cfg := Load(nested); cfg.Profile != "walked-up" {
		t.Errorf("expected the ancestor's config, got %q", cfg.Profile)
	}
}

// A broken config file must not make every command unusable.
func TestMalformedConfigIsIgnoredNotFatal(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, ".conductor.json"), []byte(`{not json`), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("CONDUCTOR_URL", "https://still-works.test")

	cfg := Load(dir)
	if cfg.APIURL != "https://still-works.test" {
		t.Errorf("a malformed file must be skipped, got %q", cfg.APIURL)
	}
}

// Config must not carry a token at all — that invariant now lives in
// internal/auth, and is asserted there (TestAConfigFileCannotSupplyAToken).
// A config file naming a token must still be harmless.
func TestAConfigFileWithATokenFieldIsIgnoredSafely(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, ".conductor.json"),
		[]byte(`{"api_url":"https://x.test","token":"leaked_from_file"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("CONDUCTOR_URL", "")

	cfg := Load(dir)
	if _, ok := cfg.Sources["token"]; ok {
		t.Error("config must not claim a token source; auth owns the token")
	}

}

// The attack this prevents: clone a hostile repo, run `conductor` inside it, and
// its .conductor.json points api_url at the attacker — who receives whatever
// CONDUCTOR_MCP_TOKEN is exported in that shell. A project file is attacker-
// supplied by definition, so it may carry settings but never the host a
// credential is sent to.
func TestAProjectFileCannotRedirectTheAPIURL(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, ".conductor.json"),
		[]byte(`{"api_url":"https://evil.example.com","profile":"harmless"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("CONDUCTOR_URL", "")
	t.Setenv("CONDUCTOR_PROFILE", "")

	cfg := Load(dir)

	if cfg.APIURL == "https://evil.example.com" {
		t.Fatal("a project file redirected the API URL — this is the token-exfiltration path")
	}
	if cfg.APIURL != "" {
		t.Errorf("expected no api_url from a project file, got %q", cfg.APIURL)
	}
	// Non-sensitive settings still apply: the file is not ignored, only limited.
	if cfg.Profile != "harmless" {
		t.Errorf("a project file should still set a profile, got %q", cfg.Profile)
	}
}

// The global file is the user's own, so it keeps the privilege a project file loses.
func TestTheGlobalFileMaySetTheAPIURL(t *testing.T) {
	home := t.TempDir()
	if err := os.WriteFile(filepath.Join(home, ".conductor.json"),
		[]byte(`{"api_url":"https://mine.example.com"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("HOME", home)
	t.Setenv("CONDUCTOR_URL", "")

	if cfg := Load(t.TempDir()); cfg.APIURL != "https://mine.example.com" {
		t.Errorf("the global file should set api_url, got %q", cfg.APIURL)
	}
}
