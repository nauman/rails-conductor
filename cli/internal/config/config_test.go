package config

import (
	"os"
	"path/filepath"
	"testing"
)

func TestPrecedenceFlagsBeatEnvBeatsProjectBeatsGlobal(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, ".conductor.json"),
		[]byte(`{"api_url":"https://from-project.test"}`), 0o600); err != nil {
		t.Fatal(err)
	}

	// Project file alone.
	t.Setenv("CONDUCTOR_URL", "")
	cfg := Load(dir)
	if cfg.APIURL != "https://from-project.test" {
		t.Errorf("project file should apply, got %q", cfg.APIURL)
	}

	// Env beats the project file.
	t.Setenv("CONDUCTOR_URL", "https://from-env.test")
	cfg = Load(dir)
	if cfg.APIURL != "https://from-env.test" {
		t.Errorf("env must beat the project file, got %q", cfg.APIURL)
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

func TestProjectFileIsFoundByWalkingUp(t *testing.T) {
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, ".conductor.json"),
		[]byte(`{"api_url":"https://walked-up.test"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	nested := filepath.Join(root, "a", "b", "c")
	if err := os.MkdirAll(nested, 0o755); err != nil {
		t.Fatal(err)
	}

	t.Setenv("CONDUCTOR_URL", "")
	if cfg := Load(nested); cfg.APIURL != "https://walked-up.test" {
		t.Errorf("expected the ancestor's config, got %q", cfg.APIURL)
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
	if cfg.APIURL != "https://x.test" {
		t.Errorf("the url should still load, got %q", cfg.APIURL)
	}
	if _, ok := cfg.Sources["token"]; ok {
		t.Error("config must not claim a token source; auth owns the token")
	}
}
