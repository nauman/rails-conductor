mod auth;
mod client;
mod commands;
mod config;
mod output;

use anyhow::Result;
use clap::{Parser, Subcommand};
use colored::Colorize;

use client::Client;
use config::Config;

#[derive(Parser)]
#[command(
    name = "conductor",
    version,
    about = "Conductor infrastructure CLI",
    long_about = "Command-line interface for managing servers, apps, scripts, and backups via the Conductor API."
)]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// Authenticate with a Conductor instance
    Login {
        /// Conductor server URL (prompted interactively if not provided)
        #[arg(long)]
        url: Option<String>,
    },

    /// Show current authentication status
    Whoami,

    /// Log out and clear saved credentials
    Logout,

    /// Manage servers
    #[command(subcommand)]
    Servers(ServersCommand),

    /// Manage apps
    #[command(subcommand)]
    Apps(AppsCommand),

    /// Manage scripts
    #[command(subcommand)]
    Scripts(ScriptsCommand),

    /// Manage backups
    #[command(subcommand)]
    Backups(BackupsCommand),

    /// Show fleet overview
    Status,
}

#[derive(Subcommand)]
enum ServersCommand {
    /// List all servers
    List,
    /// Show details for a specific server
    Show {
        /// Server name or numeric ID
        name_or_id: String,
    },
    /// Add a new server
    Add {
        /// Server name
        name: String,
        /// IP address
        ip: String,
    },
    /// Trigger provisioning for a server
    Provision {
        /// Server name or numeric ID
        name_or_id: String,
    },
    /// Show metrics for a server
    Metrics {
        /// Server name or numeric ID
        name_or_id: String,
    },
}

#[derive(Subcommand)]
enum AppsCommand {
    /// List all apps
    List,
    /// Show details for a specific app
    Show {
        /// App name, slug, or numeric ID
        name_or_id: String,
    },
    /// Deploy an app
    Deploy {
        /// App name, slug, or numeric ID
        name_or_id: String,
    },
    /// Stop a running app
    Stop {
        /// App name, slug, or numeric ID
        name_or_id: String,
    },
    /// Restart an app
    Restart {
        /// App name, slug, or numeric ID
        name_or_id: String,
    },
    /// View logs for an app
    Logs {
        /// App name, slug, or numeric ID
        name_or_id: String,
    },
}

#[derive(Subcommand)]
enum ScriptsCommand {
    /// List all available scripts
    List,
    /// Show details for a specific script
    Show {
        /// Script name or numeric ID
        name_or_id: String,
    },
    /// Run a script on a server
    Run {
        /// Script name or numeric ID
        script: String,
        /// Target server name or numeric ID
        server: String,
    },
}

#[derive(Subcommand)]
enum BackupsCommand {
    /// List all backups
    List,
    /// Show details for a specific backup
    Show {
        /// Backup numeric ID
        name_or_id: String,
    },
    /// Trigger a backup run
    Run {
        /// Backup numeric ID
        name_or_id: String,
    },
}

#[tokio::main]
async fn main() {
    let cli = Cli::parse();

    if let Err(err) = run(cli).await {
        eprintln!("  {} {}", "Error:".red().bold(), err);
        // Print the chain of causes for context
        let mut source = err.source();
        while let Some(cause) = source {
            eprintln!("  {} {}", "Caused by:".red(), cause);
            source = std::error::Error::source(cause);
        }
        std::process::exit(1);
    }
}

async fn run(cli: Cli) -> Result<()> {
    match cli.command {
        // Auth commands (don't need an authenticated client)
        Commands::Login { url } => auth::login(url).await,
        Commands::Whoami => auth::status(),
        Commands::Logout => auth::logout(),

        // All other commands need an authenticated client
        Commands::Status => {
            let client = make_client()?;
            commands::status::show(&client).await
        }

        Commands::Servers(cmd) => {
            let client = make_client()?;
            match cmd {
                ServersCommand::List => commands::servers::list(&client).await,
                ServersCommand::Show { name_or_id } => {
                    commands::servers::show(&client, &name_or_id).await
                }
                ServersCommand::Add { name, ip } => {
                    commands::servers::add(&client, &name, &ip).await
                }
                ServersCommand::Provision { name_or_id } => {
                    commands::servers::provision(&client, &name_or_id).await
                }
                ServersCommand::Metrics { name_or_id } => {
                    commands::servers::metrics(&client, &name_or_id).await
                }
            }
        }

        Commands::Apps(cmd) => {
            let client = make_client()?;
            match cmd {
                AppsCommand::List => commands::apps::list(&client).await,
                AppsCommand::Show { name_or_id } => {
                    commands::apps::show(&client, &name_or_id).await
                }
                AppsCommand::Deploy { name_or_id } => {
                    commands::apps::deploy(&client, &name_or_id).await
                }
                AppsCommand::Stop { name_or_id } => {
                    commands::apps::stop(&client, &name_or_id).await
                }
                AppsCommand::Restart { name_or_id } => {
                    commands::apps::restart(&client, &name_or_id).await
                }
                AppsCommand::Logs { name_or_id } => {
                    commands::apps::logs(&client, &name_or_id).await
                }
            }
        }

        Commands::Scripts(cmd) => {
            let client = make_client()?;
            match cmd {
                ScriptsCommand::List => commands::scripts::list(&client).await,
                ScriptsCommand::Show { name_or_id } => {
                    commands::scripts::show(&client, &name_or_id).await
                }
                ScriptsCommand::Run { script, server } => {
                    commands::scripts::run(&client, &script, &server).await
                }
            }
        }

        Commands::Backups(cmd) => {
            let client = make_client()?;
            match cmd {
                BackupsCommand::List => commands::backups::list(&client).await,
                BackupsCommand::Show { name_or_id } => {
                    commands::backups::show(&client, &name_or_id).await
                }
                BackupsCommand::Run { name_or_id } => {
                    commands::backups::run(&client, &name_or_id).await
                }
            }
        }
    }
}

/// Load config and create an authenticated API client.
fn make_client() -> Result<Client> {
    let config = Config::load()?;
    Client::new(&config)
}
