use anyhow::{Context, Result};
use colored::Colorize;
use serde_json::json;

use crate::client::Client;
use crate::output::{
    color_status, format_timestamp, json_float, json_int, json_str, print_detail, print_info,
    print_section, print_success, print_table,
};

/// List all servers in a table.
pub async fn list(client: &Client) -> Result<()> {
    let servers = client
        .get("/api/v1/servers")
        .await
        .context("Failed to fetch servers")?;

    let items = servers
        .as_array()
        .ok_or_else(|| anyhow::anyhow!("Unexpected response format: expected array"))?;

    print_section("Servers");

    let headers = &["ID", "NAME", "HOSTNAME", "IP ADDRESS", "PROVIDER", "STATUS"];
    let rows: Vec<Vec<String>> = items
        .iter()
        .map(|s| {
            vec![
                json_int(s, "id"),
                json_str(s, "name"),
                json_str(s, "hostname"),
                json_str(s, "ip_address"),
                json_str(s, "provider"),
                format!("{}", color_status(&json_str(s, "status"))),
            ]
        })
        .collect();

    print_table(headers, &rows);
    println!();
    print_info(&format!("{} server(s) total", items.len()));
    println!();

    Ok(())
}

/// Show detailed info about a single server.
pub async fn show(client: &Client, name_or_id: &str) -> Result<()> {
    let server = find_server(client, name_or_id).await?;

    print_section(&format!("Server: {}", json_str(&server, "name")));

    print_detail("ID", &json_int(&server, "id"));
    print_detail("Name", &json_str(&server, "name"));
    print_detail("Hostname", &json_str(&server, "hostname"));
    print_detail("IP Address", &json_str(&server, "ip_address"));
    print_detail("Provider", &json_str(&server, "provider"));
    print_detail(
        "Status",
        &format!("{}", color_status(&json_str(&server, "status"))),
    );
    print_detail("SSH User", &json_str(&server, "ssh_user"));
    print_detail("SSH Port", &json_int(&server, "ssh_port"));

    // Metrics
    let cpu = json_float(&server, "cpu_percent");
    let mem_used = json_int(&server, "memory_used_mb");
    let mem_total = json_int(&server, "memory_total_mb");
    let disk = json_float(&server, "disk_percent");

    println!();
    print_detail("CPU", &format!("{}%", cpu));
    print_detail("Memory", &format!("{} / {} MB", mem_used, mem_total));
    print_detail("Disk", &format!("{}%", disk));

    println!();
    let last_seen = json_str(&server, "last_seen_at");
    let created = json_str(&server, "created_at");
    print_detail("Last Seen", &if last_seen != "-" { format_timestamp(&last_seen) } else { "-".to_string() });
    print_detail("Created", &if created != "-" { format_timestamp(&created) } else { "-".to_string() });
    println!();

    Ok(())
}

/// Add a new server.
pub async fn add(client: &Client, name: &str, ip: &str) -> Result<()> {
    print_info(&format!("Adding server '{}' at {}...", name, ip));

    let body = json!({
        "server": {
            "name": name,
            "hostname": name,
            "ip_address": ip,
            "status": "offline"
        }
    });

    let result = client
        .post("/api/v1/servers", Some(body))
        .await
        .context("Failed to add server")?;

    let server_name = json_str(&result, "name");
    let server_id = json_int(&result, "id");
    print_success(&format!(
        "Server '{}' created with ID {}",
        server_name, server_id
    ));
    println!();

    Ok(())
}

/// Trigger provisioning for a server.
pub async fn provision(client: &Client, name_or_id: &str) -> Result<()> {
    let server = find_server(client, name_or_id).await?;
    let server_id = server
        .get("id")
        .and_then(|v| v.as_i64())
        .ok_or_else(|| anyhow::anyhow!("Server has no ID"))?;

    let server_name = json_str(&server, "name");
    print_info(&format!("Provisioning server '{}'...", server_name));

    let result = client
        .post(&format!("/api/v1/servers/{}/provision", server_id), None)
        .await
        .context("Failed to start provisioning")?;

    let message = result
        .get("message")
        .and_then(|v| v.as_str())
        .unwrap_or("Provisioning started");
    print_success(message);
    println!();

    Ok(())
}

/// Show metrics for a server.
pub async fn metrics(client: &Client, name_or_id: &str) -> Result<()> {
    let server = find_server(client, name_or_id).await?;
    let server_id = server
        .get("id")
        .and_then(|v| v.as_i64())
        .ok_or_else(|| anyhow::anyhow!("Server has no ID"))?;

    let result = client
        .get(&format!("/api/v1/servers/{}/metrics", server_id))
        .await
        .context("Failed to fetch server metrics")?;

    let server_name = json_str(&result, "name");
    print_section(&format!("Metrics: {}", server_name));

    if let Some(m) = result.get("metrics") {
        let cpu = json_float(m, "cpu_percent");
        let mem_used = json_int(m, "memory_used_mb");
        let mem_total = json_int(m, "memory_total_mb");
        let disk = json_float(m, "disk_percent");
        let fresh = m
            .get("metrics_fresh")
            .and_then(|v| v.as_bool())
            .unwrap_or(false);
        let formatted_mem = json_str(m, "formatted_memory");

        print_detail("CPU Usage", &format!("{}%", cpu));
        print_detail("Memory", &if formatted_mem != "-" { formatted_mem } else { format!("{} / {} MB", mem_used, mem_total) });
        print_detail("Disk Usage", &format!("{}%", disk));
        print_detail(
            "Data Fresh",
            &format!(
                "{}",
                if fresh {
                    "yes".green()
                } else {
                    "stale".yellow()
                }
            ),
        );
    } else {
        // Fall back to top-level metrics
        let cpu = json_float(&result, "cpu_percent");
        let mem_used = json_int(&result, "memory_used_mb");
        let mem_total = json_int(&result, "memory_total_mb");
        let disk = json_float(&result, "disk_percent");

        print_detail("CPU Usage", &format!("{}%", cpu));
        print_detail("Memory", &format!("{} / {} MB", mem_used, mem_total));
        print_detail("Disk Usage", &format!("{}%", disk));
    }

    println!();
    Ok(())
}

/// Find a server by name or numeric ID.
/// If the input parses as an integer, fetch by ID directly.
/// Otherwise, list all servers and find by name match.
async fn find_server(client: &Client, name_or_id: &str) -> Result<serde_json::Value> {
    // Try as numeric ID first
    if let Ok(id) = name_or_id.parse::<i64>() {
        return client
            .get(&format!("/api/v1/servers/{}", id))
            .await
            .with_context(|| format!("Server with ID {} not found", id));
    }

    // Otherwise, search by name
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
        1 => Ok(matching[0].clone()),
        _ => anyhow::bail!(
            "Multiple servers found with name '{}'. Use the numeric ID instead.",
            name_or_id
        ),
    }
}
