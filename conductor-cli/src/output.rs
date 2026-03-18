use colored::{ColoredString, Colorize};

/// Print a formatted table with headers and rows.
///
/// Column widths are computed dynamically based on the longest value in each column
/// (including the header). Headers are printed in bold cyan, with a separator line below.
pub fn print_table(headers: &[&str], rows: &[Vec<String>]) {
    if rows.is_empty() {
        println!("  No results found.");
        return;
    }

    // Compute column widths: max of header length and all row values for that column
    let col_count = headers.len();
    let mut widths: Vec<usize> = headers.iter().map(|h| h.len()).collect();

    for row in rows {
        for (i, cell) in row.iter().enumerate() {
            if i < col_count {
                widths[i] = widths[i].max(cell.len());
            }
        }
    }

    // Add padding
    let padding = 2;

    // Print header row
    let header_line: Vec<String> = headers
        .iter()
        .enumerate()
        .map(|(i, h)| format!("{:<width$}", h, width = widths[i] + padding))
        .collect();
    println!("  {}", header_line.join("").bold().cyan());

    // Print separator
    let separator: Vec<String> = widths
        .iter()
        .map(|w| format!("{:<width$}", "-".repeat(*w), width = w + padding))
        .collect();
    println!("  {}", separator.join("").dimmed());

    // Print data rows
    for row in rows {
        let line: Vec<String> = row
            .iter()
            .enumerate()
            .map(|(i, cell)| {
                let w = widths.get(i).copied().unwrap_or(cell.len());
                format!("{:<width$}", cell, width = w + padding)
            })
            .collect();
        println!("  {}", line.join(""));
    }
}

/// Color a status string based on its value.
///
/// - Green: online, running, active, success, enabled, completed
/// - Red: offline, stopped, failed, error, disabled
/// - Yellow: pending, deploying, degraded, provisioning, warning
/// - Default (white): anything else
pub fn color_status(status: &str) -> ColoredString {
    match status.to_lowercase().as_str() {
        "online" | "running" | "active" | "success" | "enabled" | "completed" => {
            status.green().bold()
        }
        "offline" | "stopped" | "failed" | "error" | "disabled" => status.red().bold(),
        "pending" | "deploying" | "degraded" | "provisioning" | "warning" | "queued" => {
            status.yellow().bold()
        }
        _ => status.normal(),
    }
}

/// Format a boolean as a colored yes/no string.
#[allow(dead_code)]
pub fn format_bool(value: bool) -> ColoredString {
    if value {
        "yes".green()
    } else {
        "no".red()
    }
}

/// Print a key-value detail line, used for "show" commands.
pub fn print_detail(label: &str, value: &str) {
    println!(
        "  {:<20} {}",
        format!("{}:", label).dimmed(),
        value
    );
}

/// Print a section header.
pub fn print_section(title: &str) {
    println!();
    println!("  {}", title.bold().underline());
    println!();
}

/// Print a success message.
pub fn print_success(message: &str) {
    println!("  {} {}", "OK".green().bold(), message);
}

/// Print an info message.
pub fn print_info(message: &str) {
    println!("  {} {}", "->".cyan().bold(), message);
}

/// Format an optional JSON string value, returning "-" for null/missing.
pub fn json_str(value: &serde_json::Value, key: &str) -> String {
    value
        .get(key)
        .and_then(|v| v.as_str())
        .unwrap_or("-")
        .to_string()
}

/// Format an optional JSON integer value, returning "-" for null/missing.
pub fn json_int(value: &serde_json::Value, key: &str) -> String {
    value
        .get(key)
        .and_then(|v| v.as_i64())
        .map(|v| v.to_string())
        .unwrap_or_else(|| "-".to_string())
}

/// Format an optional JSON float value, returning "-" for null/missing.
pub fn json_float(value: &serde_json::Value, key: &str) -> String {
    value
        .get(key)
        .and_then(|v| v.as_f64())
        .map(|v| format!("{:.1}", v))
        .unwrap_or_else(|| "-".to_string())
}

/// Format an optional JSON boolean value, returning "-" for null/missing.
pub fn json_bool(value: &serde_json::Value, key: &str) -> String {
    value
        .get(key)
        .and_then(|v| v.as_bool())
        .map(|v| if v { "yes".to_string() } else { "no".to_string() })
        .unwrap_or_else(|| "-".to_string())
}

/// Format an ISO 8601 timestamp into a shorter human-readable form.
/// Input:  "2026-03-04T12:34:56+00:00"
/// Output: "2026-03-04 12:34"
pub fn format_timestamp(iso: &str) -> String {
    // Take the first 16 chars and replace T with space
    if iso.len() >= 16 {
        iso[..16].replace('T', " ")
    } else {
        iso.to_string()
    }
}
