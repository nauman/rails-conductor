use anyhow::{Context, Result};
use colored::Colorize;

use crate::client::Client;
use crate::output::{
    color_status, format_timestamp, json_bool, json_int, json_str, print_detail, print_info,
    print_section, print_success, print_table,
};

/// List all apps in a table.
pub async fn list(client: &Client) -> Result<()> {
    let apps = client
        .get("/api/v1/apps")
        .await
        .context("Failed to fetch apps")?;

    let items = apps
        .as_array()
        .ok_or_else(|| anyhow::anyhow!("Unexpected response format: expected array"))?;

    print_section("Apps");

    let headers = &["ID", "NAME", "SERVER", "DOMAIN", "STATUS", "DEPLOYED"];
    let rows: Vec<Vec<String>> = items
        .iter()
        .map(|a| {
            let deployed = json_str(a, "deployed_at");
            let deployed_fmt = if deployed != "-" {
                format_timestamp(&deployed)
            } else {
                "-".to_string()
            };
            vec![
                json_int(a, "id"),
                json_str(a, "name"),
                json_str(a, "server"),
                json_str(a, "domain"),
                format!("{}", color_status(&json_str(a, "status"))),
                deployed_fmt,
            ]
        })
        .collect();

    print_table(headers, &rows);
    println!();
    print_info(&format!("{} app(s) total", items.len()));
    println!();

    Ok(())
}

/// Show detailed info about a single app.
pub async fn show(client: &Client, name_or_id: &str) -> Result<()> {
    let app = find_app(client, name_or_id).await?;

    print_section(&format!("App: {}", json_str(&app, "name")));

    print_detail("ID", &json_int(&app, "id"));
    print_detail("Name", &json_str(&app, "name"));
    print_detail("Slug", &json_str(&app, "slug"));
    print_detail(
        "Status",
        &format!("{}", color_status(&json_str(&app, "status"))),
    );
    print_detail("Domain", &json_str(&app, "domain"));
    print_detail("Port", &json_int(&app, "port"));
    print_detail("Server", &json_str(&app, "server"));
    print_detail("Repository", &json_str(&app, "repository_url"));
    print_detail("Branch", &json_str(&app, "branch"));
    print_detail("Container", &json_str(&app, "container_status"));
    print_detail("SSL", &json_bool(&app, "ssl_enabled"));

    println!();
    let deployed = json_str(&app, "deployed_at");
    let created = json_str(&app, "created_at");
    print_detail(
        "Last Deploy",
        &if deployed != "-" {
            format_timestamp(&deployed)
        } else {
            "-".to_string()
        },
    );
    print_detail(
        "Created",
        &if created != "-" {
            format_timestamp(&created)
        } else {
            "-".to_string()
        },
    );
    println!();

    Ok(())
}

/// Deploy an app.
pub async fn deploy(client: &Client, name_or_id: &str) -> Result<()> {
    let app = find_app(client, name_or_id).await?;
    let app_id = app
        .get("id")
        .and_then(|v| v.as_i64())
        .ok_or_else(|| anyhow::anyhow!("App has no ID"))?;
    let app_name = json_str(&app, "name");

    print_info(&format!("Deploying '{}'...", app_name));

    let result = client
        .post(&format!("/api/v1/apps/{}/deploy", app_id), None)
        .await
        .context("Failed to start deploy")?;

    let message = result
        .get("message")
        .and_then(|v| v.as_str())
        .unwrap_or("Deploy started");
    print_success(message);
    println!();

    Ok(())
}

/// Stop an app.
pub async fn stop(client: &Client, name_or_id: &str) -> Result<()> {
    let app = find_app(client, name_or_id).await?;
    let app_id = app
        .get("id")
        .and_then(|v| v.as_i64())
        .ok_or_else(|| anyhow::anyhow!("App has no ID"))?;
    let app_name = json_str(&app, "name");

    print_info(&format!("Stopping '{}'...", app_name));

    let result = client
        .post(&format!("/api/v1/apps/{}/stop", app_id), None)
        .await
        .context("Failed to stop app")?;

    let message = result
        .get("message")
        .and_then(|v| v.as_str())
        .unwrap_or("Stop requested");
    print_success(message);
    println!();

    Ok(())
}

/// Restart an app.
pub async fn restart(client: &Client, name_or_id: &str) -> Result<()> {
    let app = find_app(client, name_or_id).await?;
    let app_id = app
        .get("id")
        .and_then(|v| v.as_i64())
        .ok_or_else(|| anyhow::anyhow!("App has no ID"))?;
    let app_name = json_str(&app, "name");

    print_info(&format!("Restarting '{}'...", app_name));

    let result = client
        .post(&format!("/api/v1/apps/{}/restart", app_id), None)
        .await
        .context("Failed to restart app")?;

    let message = result
        .get("message")
        .and_then(|v| v.as_str())
        .unwrap_or("Restart requested");
    print_success(message);
    println!();

    Ok(())
}

/// Fetch and display logs for an app.
pub async fn logs(client: &Client, name_or_id: &str) -> Result<()> {
    let app = find_app(client, name_or_id).await?;
    let app_id = app
        .get("id")
        .and_then(|v| v.as_i64())
        .ok_or_else(|| anyhow::anyhow!("App has no ID"))?;
    let app_name = json_str(&app, "name");

    let result = client
        .get(&format!("/api/v1/apps/{}/logs", app_id))
        .await
        .context("Failed to fetch logs")?;

    print_section(&format!("Logs: {}", app_name));

    if let Some(log_lines) = result.get("logs").and_then(|v| v.as_array()) {
        if log_lines.is_empty() {
            println!("  {}", "No log entries available.".dimmed());
        } else {
            for line in log_lines {
                if let Some(text) = line.as_str() {
                    println!("  {}", text);
                } else {
                    println!("  {}", line);
                }
            }
        }
    } else {
        println!("  {}", "No log entries available.".dimmed());
    }

    println!();
    Ok(())
}

/// Find an app by name or numeric ID.
async fn find_app(client: &Client, name_or_id: &str) -> Result<serde_json::Value> {
    // Try as numeric ID first
    if let Ok(id) = name_or_id.parse::<i64>() {
        return client
            .get(&format!("/api/v1/apps/{}", id))
            .await
            .with_context(|| format!("App with ID {} not found", id));
    }

    // Otherwise, search by name
    let apps = client
        .get("/api/v1/apps")
        .await
        .context("Failed to fetch apps")?;

    let items = apps
        .as_array()
        .ok_or_else(|| anyhow::anyhow!("Unexpected response format"))?;

    let lower_name = name_or_id.to_lowercase();
    let matching: Vec<&serde_json::Value> = items
        .iter()
        .filter(|a| {
            let name_match = a
                .get("name")
                .and_then(|n| n.as_str())
                .map(|n| n.to_lowercase() == lower_name)
                .unwrap_or(false);
            let slug_match = a
                .get("slug")
                .and_then(|n| n.as_str())
                .map(|n| n.to_lowercase() == lower_name)
                .unwrap_or(false);
            name_match || slug_match
        })
        .collect();

    match matching.len() {
        0 => anyhow::bail!("No app found with name '{}'", name_or_id),
        1 => Ok(matching[0].clone()),
        _ => anyhow::bail!(
            "Multiple apps found matching '{}'. Use the numeric ID instead.",
            name_or_id
        ),
    }
}
