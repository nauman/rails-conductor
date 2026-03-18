use anyhow::{Context, Result};

use crate::client::Client;
use crate::output::{
    color_status, format_timestamp, json_bool, json_int, json_str, print_detail, print_info,
    print_section, print_success, print_table,
};

/// List all backups in a table.
pub async fn list(client: &Client) -> Result<()> {
    let backups = client
        .get("/api/v1/backups")
        .await
        .context("Failed to fetch backups")?;

    let items = backups
        .as_array()
        .ok_or_else(|| anyhow::anyhow!("Unexpected response format: expected array"))?;

    print_section("Backups");

    let headers = &["ID", "PROVIDER", "BUCKET", "SERVER", "APP", "STATUS", "ENABLED", "LAST RUN"];
    let rows: Vec<Vec<String>> = items
        .iter()
        .map(|b| {
            let last_run = json_str(b, "last_run_at");
            let last_run_fmt = if last_run != "-" {
                format_timestamp(&last_run)
            } else {
                "-".to_string()
            };
            vec![
                json_int(b, "id"),
                json_str(b, "provider"),
                json_str(b, "bucket_name"),
                json_str(b, "server"),
                json_str(b, "app"),
                format!("{}", color_status(&json_str(b, "status"))),
                json_bool(b, "enabled"),
                last_run_fmt,
            ]
        })
        .collect();

    print_table(headers, &rows);
    println!();
    print_info(&format!("{} backup(s) total", items.len()));
    println!();

    Ok(())
}

/// Show detailed info about a single backup.
pub async fn show(client: &Client, name_or_id: &str) -> Result<()> {
    let backup = find_backup(client, name_or_id).await?;

    let provider = json_str(&backup, "provider");
    let bucket = json_str(&backup, "bucket_name");
    print_section(&format!("Backup: {} ({})", bucket, provider));

    print_detail("ID", &json_int(&backup, "id"));
    print_detail("Provider", &provider);
    print_detail("Bucket", &bucket);
    print_detail("Schedule", &json_str(&backup, "schedule"));
    print_detail("Enabled", &json_bool(&backup, "enabled"));
    print_detail(
        "Status",
        &format!("{}", color_status(&json_str(&backup, "status"))),
    );
    print_detail("Server", &json_str(&backup, "server"));
    print_detail("App", &json_str(&backup, "app"));
    print_detail("Retention", &format!("{} days", json_int(&backup, "retention_days")));

    // Format size nicely
    let size_bytes = backup
        .get("size_bytes")
        .and_then(|v| v.as_u64());
    let size_str = match size_bytes {
        Some(bytes) if bytes >= 1_073_741_824 => format!("{:.1} GB", bytes as f64 / 1_073_741_824.0),
        Some(bytes) if bytes >= 1_048_576 => format!("{:.1} MB", bytes as f64 / 1_048_576.0),
        Some(bytes) if bytes >= 1024 => format!("{:.1} KB", bytes as f64 / 1024.0),
        Some(bytes) => format!("{} B", bytes),
        None => "-".to_string(),
    };
    print_detail("Size", &size_str);

    println!();
    let last_run = json_str(&backup, "last_run_at");
    let next_run = json_str(&backup, "next_run_at");
    let created = json_str(&backup, "created_at");
    print_detail(
        "Last Run",
        &if last_run != "-" { format_timestamp(&last_run) } else { "-".to_string() },
    );
    print_detail(
        "Next Run",
        &if next_run != "-" { format_timestamp(&next_run) } else { "-".to_string() },
    );
    print_detail(
        "Created",
        &if created != "-" { format_timestamp(&created) } else { "-".to_string() },
    );
    println!();

    Ok(())
}

/// Trigger a backup run.
pub async fn run(client: &Client, name_or_id: &str) -> Result<()> {
    let backup = find_backup(client, name_or_id).await?;
    let backup_id = backup
        .get("id")
        .and_then(|v| v.as_i64())
        .ok_or_else(|| anyhow::anyhow!("Backup has no ID"))?;

    let bucket = json_str(&backup, "bucket_name");
    print_info(&format!("Triggering backup '{}'...", bucket));

    let result = client
        .post(&format!("/api/v1/backups/{}/run", backup_id), None)
        .await
        .context("Failed to trigger backup")?;

    let message = result
        .get("message")
        .and_then(|v| v.as_str())
        .unwrap_or("Backup triggered");
    print_success(message);
    println!();

    Ok(())
}

/// Find a backup by numeric ID (backups don't have unique names, so ID is required).
async fn find_backup(client: &Client, id_str: &str) -> Result<serde_json::Value> {
    let id: i64 = id_str
        .parse()
        .with_context(|| format!("'{}' is not a valid backup ID. Use a numeric ID.", id_str))?;

    client
        .get(&format!("/api/v1/backups/{}", id))
        .await
        .with_context(|| format!("Backup with ID {} not found", id))
}
