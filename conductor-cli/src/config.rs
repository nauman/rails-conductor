use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::PathBuf;

#[derive(Serialize, Deserialize, Default, Clone)]
pub struct Config {
    pub url: Option<String>,
    pub token: Option<String>,
}

impl Config {
    /// Load configuration from ~/.conductor/config.toml
    pub fn load() -> Result<Self> {
        let path = Self::path();
        if !path.exists() {
            return Ok(Self::default());
        }

        let contents = fs::read_to_string(&path)
            .with_context(|| format!("Failed to read config file: {}", path.display()))?;

        let config: Config = toml::from_str(&contents)
            .with_context(|| format!("Failed to parse config file: {}", path.display()))?;

        Ok(config)
    }

    /// Save configuration to ~/.conductor/config.toml
    pub fn save(&self) -> Result<()> {
        let path = Self::path();

        // Ensure the parent directory exists
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)
                .with_context(|| format!("Failed to create config directory: {}", parent.display()))?;
        }

        let contents = toml::to_string_pretty(self)
            .context("Failed to serialize config")?;

        fs::write(&path, contents)
            .with_context(|| format!("Failed to write config file: {}", path.display()))?;

        Ok(())
    }

    /// Returns the path to the config file: ~/.conductor/config.toml
    pub fn path() -> PathBuf {
        dirs::home_dir()
            .expect("Could not determine home directory")
            .join(".conductor")
            .join("config.toml")
    }

    /// Returns the base URL, or an error if not configured
    pub fn require_url(&self) -> Result<&str> {
        self.url
            .as_deref()
            .filter(|u| !u.is_empty())
            .ok_or_else(|| anyhow::anyhow!("Not logged in. Run `conductor login` first."))
    }

    /// Returns the API token, or an error if not configured
    pub fn require_token(&self) -> Result<&str> {
        self.token
            .as_deref()
            .filter(|t| !t.is_empty())
            .ok_or_else(|| anyhow::anyhow!("Not logged in. Run `conductor login` first."))
    }
}
