use anyhow::{Context, Result};
use colored::Colorize;
use std::io::{self, Write};

use crate::client::Client;
use crate::config::Config;

/// Interactive login flow:
/// 1. Prompt for Conductor server URL (if not provided)
/// 2. Prompt for API token (generated via the web UI)
/// 3. Verify the token works by calling /api/v1/status
/// 4. Save the URL and token to ~/.conductor/config.toml
pub async fn login(url: Option<String>) -> Result<()> {
    println!("{}", "Conductor CLI Login".bold());
    println!();

    // Step 1: Get the server URL
    let server_url = match url {
        Some(u) => {
            println!("  Server URL: {}", u.cyan());
            u
        }
        None => {
            print!("  Enter Conductor server URL (e.g. https://conductor.example.com): ");
            io::stdout().flush().context("Failed to flush stdout")?;
            let mut input = String::new();
            io::stdin()
                .read_line(&mut input)
                .context("Failed to read URL input")?;
            let trimmed = input.trim().to_string();
            if trimmed.is_empty() {
                anyhow::bail!("URL cannot be empty");
            }
            trimmed
        }
    };

    // Normalize URL: strip trailing slash
    let server_url = server_url.trim_end_matches('/').to_string();

    // Step 2: Get the API token
    println!();
    println!(
        "  Generate an API token in the Conductor web UI, then paste it here."
    );
    print!("  Enter API token: ");
    io::stdout().flush().context("Failed to flush stdout")?;
    let mut token_input = String::new();
    io::stdin()
        .read_line(&mut token_input)
        .context("Failed to read token input")?;
    let token = token_input.trim().to_string();
    if token.is_empty() {
        anyhow::bail!("Token cannot be empty");
    }

    // Step 3: Verify the token by calling the status endpoint
    println!();
    print!("  Verifying credentials... ");
    io::stdout().flush().context("Failed to flush stdout")?;

    let client = Client::new_with_credentials(&server_url, &token)?;
    match client.get("/api/v1/status").await {
        Ok(status) => {
            println!("{}", "OK".green().bold());
            println!();

            // Show a brief summary of what we connected to
            if let Some(servers) = status.get("servers") {
                let total = servers.get("total").and_then(|v| v.as_u64()).unwrap_or(0);
                let online = servers.get("online").and_then(|v| v.as_u64()).unwrap_or(0);
                println!(
                    "  Connected to {} - {} server(s), {} online",
                    server_url.cyan(),
                    total,
                    online
                );
            } else {
                println!("  Connected to {}", server_url.cyan());
            }
        }
        Err(e) => {
            println!("{}", "FAILED".red().bold());
            println!();
            anyhow::bail!(
                "Could not verify credentials: {}. Check your URL and token.",
                e
            );
        }
    }

    // Step 4: Save to config
    let config = Config {
        url: Some(server_url),
        token: Some(token),
    };
    config.save().context("Failed to save configuration")?;

    println!();
    println!(
        "  {} Configuration saved to {}",
        "Done!".green().bold(),
        Config::path().display()
    );
    println!();

    Ok(())
}

/// Show current login status
pub fn status() -> Result<()> {
    let config = Config::load()?;

    match (&config.url, &config.token) {
        (Some(url), Some(token)) if !url.is_empty() && !token.is_empty() => {
            println!("  Logged in to: {}", url.cyan());
            println!(
                "  Token:        {}...{}",
                &token[..4.min(token.len())],
                &token[token.len().saturating_sub(4)..]
            );
            println!("  Config:       {}", Config::path().display());
        }
        _ => {
            println!("  {}", "Not logged in.".yellow());
            println!("  Run `conductor login` to authenticate.");
        }
    }

    Ok(())
}

/// Log out by clearing the saved credentials
pub fn logout() -> Result<()> {
    let mut config = Config::load()?;
    config.url = None;
    config.token = None;
    config.save()?;
    println!("  {} Logged out successfully.", "Done!".green().bold());
    Ok(())
}
