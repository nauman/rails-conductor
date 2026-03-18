use anyhow::{Context, Result};
use serde_json::json;

use crate::client::Client;
use crate::output::{
    format_timestamp, json_bool, json_int, json_str, print_detail, print_info, print_section,
    print_success, print_table,
};

/// List all available scripts.
pub async fn list(client: &Client) -> Result<()> {
    let scripts = client
        .get("/api/v1/scripts")
        .await
        .context("Failed to fetch scripts")?;

    let items = scripts
        .as_array()
        .ok_or_else(|| anyhow::anyhow!("Unexpected response format: expected array"))?;

    print_section("Scripts");

    let headers = &["ID", "NAME", "TYPE", "BUILT-IN", "CREATED"];
    let rows: Vec<Vec<String>> = items
        .iter()
        .map(|s| {
            let created = json_str(s, "created_at");
            let created_fmt = if created != "-" {
                format_timestamp(&created)
            } else {
                "-".to_string()
            };
            vec![
                json_int(s, "id"),
                json_str(s, "name"),
                json_str(s, "script_type"),
                json_bool(s, "built_in"),
                created_fmt,
            ]
        })
        .collect();

    print_table(headers, &rows);
    println!();
    print_info(&format!("{} script(s) total", items.len()));
    println!();

    Ok(())
}

/// Show detailed info about a single script.
pub async fn show(client: &Client, name_or_id: &str) -> Result<()> {
    let script = find_script(client, name_or_id).await?;

    print_section(&format!("Script: {}", json_str(&script, "name")));

    print_detail("ID", &json_int(&script, "id"));
    print_detail("Name", &json_str(&script, "name"));
    print_detail("Description", &json_str(&script, "description"));
    print_detail("Type", &json_str(&script, "script_type"));
    print_detail("Built-in", &json_bool(&script, "built_in"));

    let created = json_str(&script, "created_at");
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

/// Run a script on a server.
///
/// Both `script` and `server` can be names or numeric IDs.
pub async fn run(client: &Client, script: &str, server: &str) -> Result<()> {
    // Resolve script ID
    let script_id = resolve_script_id(client, script).await?;

    // Resolve server ID
    let server_id = resolve_server_id(client, server).await?;

    print_info(&format!(
        "Running script '{}' on server '{}'...",
        script, server
    ));

    let body = json!({
        "script_id": script_id,
        "server_id": server_id
    });

    let result = client
        .post("/api/v1/scripts/run", Some(body))
        .await
        .context("Failed to start script execution")?;

    let message = result
        .get("message")
        .and_then(|v| v.as_str())
        .unwrap_or("Script execution started");

    print_success(message);

    // Show the script run details if available
    if let Some(run_info) = result.get("script_run") {
        let run_id = json_int(run_info, "id");
        let status = json_str(run_info, "status");
        print_info(&format!("Run ID: {}, Status: {}", run_id, status));
    }

    println!();
    Ok(())
}

/// Resolve a script name or ID to a numeric ID.
async fn resolve_script_id(client: &Client, name_or_id: &str) -> Result<i64> {
    if let Ok(id) = name_or_id.parse::<i64>() {
        // Verify it exists
        client
            .get(&format!("/api/v1/scripts/{}", id))
            .await
            .with_context(|| format!("Script with ID {} not found", id))?;
        return Ok(id);
    }

    let script = find_script(client, name_or_id).await?;
    script
        .get("id")
        .and_then(|v| v.as_i64())
        .ok_or_else(|| anyhow::anyhow!("Script has no ID"))
}

/// Resolve a server name or ID to a numeric ID.
async fn resolve_server_id(client: &Client, name_or_id: &str) -> Result<i64> {
    if let Ok(id) = name_or_id.parse::<i64>() {
        // Verify it exists
        client
            .get(&format!("/api/v1/servers/{}", id))
            .await
            .with_context(|| format!("Server with ID {} not found", id))?;
        return Ok(id);
    }

    // Search by name
    let servers = client
        .get("/api/v1/servers")
        .await
        .context("Failed to fetch servers")?;

    let items = servers
        .as_array()
        .ok_or_else(|| anyhow::anyhow!("Unexpected response format"))?;

    let lower_name = name_or_id.to_lowercase();
    let matching: Vec<&serde_json::Value> = items
        .iter()
        .filter(|s| {
            s.get("name")
                .and_then(|n| n.as_str())
                .map(|n| n.to_lowercase() == lower_name)
                .unwrap_or(false)
        })
        .collect();

    match matching.len() {
        0 => anyhow::bail!("No server found with name '{}'", name_or_id),
        1 => matching[0]
            .get("id")
            .and_then(|v| v.as_i64())
            .ok_or_else(|| anyhow::anyhow!("Server has no ID")),
        _ => anyhow::bail!(
            "Multiple servers found matching '{}'. Use the numeric ID instead.",
            name_or_id
        ),
    }
}

/// Find a script by name or numeric ID.
async fn find_script(client: &Client, name_or_id: &str) -> Result<serde_json::Value> {
    if let Ok(id) = name_or_id.parse::<i64>() {
        return client
            .get(&format!("/api/v1/scripts/{}", id))
            .await
            .with_context(|| format!("Script with ID {} not found", id));
    }

    let scripts = client
        .get("/api/v1/scripts")
        .await
        .context("Failed to fetch scripts")?;

    let items = scripts
        .as_array()
        .ok_or_else(|| anyhow::anyhow!("Unexpected response format"))?;

    let lower_name = name_or_id.to_lowercase();
    let matching: Vec<&serde_json::Value> = items
        .iter()
        .filter(|s| {
            s.get("name")
                .and_then(|n| n.as_str())
                .map(|n| n.to_lowercase() == lower_name)
                .unwrap_or(false)
        })
        .collect();

    match matching.len() {
        0 => anyhow::bail!("No script found with name '{}'", name_or_id),
        1 => Ok(matching[0].clone()),
        _ => anyhow::bail!(
            "Multiple scripts found matching '{}'. Use the numeric ID instead.",
            name_or_id
        ),
    }
}
