use anyhow::{Context, Result};
use colored::Colorize;

use crate::client::Client;
use crate::output::{color_status, format_timestamp, json_int, json_str, print_section};

/// Show a fleet overview: servers, apps, backups, scripts, and recent deployments.
pub async fn show(client: &Client) -> Result<()> {
    let status = client
        .get("/api/v1/status")
        .await
        .context("Failed to fetch fleet status")?;

    print_section("Fleet Overview");

    // Servers
    if let Some(servers) = status.get("servers") {
        let total = json_int(servers, "total");
        let online = json_int(servers, "online");
        let degraded = json_int(servers, "degraded");
        let offline = json_int(servers, "offline");

        println!(
            "  {:<20} {} total  |  {} {}  |  {} {}  |  {} {}",
            "Servers:".bold(),
            total,
            online,
            "online".green(),
            degraded,
            "degraded".yellow(),
            offline,
            "offline".red(),
        );
    }

    // Apps
    if let Some(apps) = status.get("apps") {
        let total = json_int(apps, "total");
        let running = json_int(apps, "running");
        let stopped = json_int(apps, "stopped");
        let deploying = json_int(apps, "deploying");
        let failed = json_int(apps, "failed");

        println!(
            "  {:<20} {} total  |  {} {}  |  {} {}  |  {} {}  |  {} {}",
            "Apps:".bold(),
            total,
            running,
            "running".green(),
            stopped,
            "stopped".dimmed(),
            deploying,
            "deploying".yellow(),
            failed,
            "failed".red(),
        );
    }

    // Backups
    if let Some(backups) = status.get("backups") {
        let total = json_int(backups, "total");
        let enabled = json_int(backups, "enabled");

        println!(
            "  {:<20} {} total  |  {} enabled",
            "Backups:".bold(),
            total,
            enabled,
        );
    }

    // Scripts
    if let Some(scripts) = status.get("scripts") {
        let total = json_int(scripts, "total");
        println!("  {:<20} {} available", "Scripts:".bold(), total);
    }

    // Recent deployments
    if let Some(deploys) = status.get("recent_deployments").and_then(|v| v.as_array()) {
        if !deploys.is_empty() {
            println!();
            println!("  {}", "Recent Deployments:".bold());
            println!(
                "  {}",
                "-".repeat(60).dimmed()
            );

            for deploy in deploys {
                let app = json_str(deploy, "app");
                let deploy_status = json_str(deploy, "status");
                let created = json_str(deploy, "created_at");
                let created_fmt = if created != "-" {
                    format_timestamp(&created)
                } else {
                    "-".to_string()
                };

                println!(
                    "    {:<20} {:<15} {}",
                    app,
                    color_status(&deploy_status),
                    created_fmt.dimmed(),
                );
            }
        }
    }

    println!();
    println!(
        "  {}",
        format!("Connected to {}", client.base_url()).dimmed()
    );
    println!();

    Ok(())
}
