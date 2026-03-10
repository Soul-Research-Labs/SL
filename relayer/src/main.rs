//! Binary entry point for the cross-chain privacy relayer daemon.
//!
//! Usage:
//!   soul-relayer --config relayer.toml
//!   soul-relayer --config relayer.toml --log-format json
//!   RUST_LOG=soul_relayer=debug soul-relayer -c relayer.toml

use clap::Parser;
use soul_relayer::{config::RelayerConfig, run_relayer};
use std::path::PathBuf;
use tracing::info;
use tracing_subscriber::{fmt, EnvFilter};

/// Cross-chain privacy relayer for the Soul Privacy Stack.
///
/// Monitors EpochManager contracts across all deployed chains,
/// relays nullifier roots via bridge adapters, and updates the
/// UniversalNullifierRegistry for global double-spend prevention.
#[derive(Parser, Debug)]
#[command(name = "soul-relayer", version, about)]
struct Cli {
    /// Path to the relayer configuration file (TOML).
    #[arg(short, long, default_value = "relayer.toml")]
    config: PathBuf,

    /// Log output format: "text" or "json".
    #[arg(long, default_value = "text")]
    log_format: String,
}

#[tokio::main]
async fn main() {
    let cli = Cli::parse();

    // Initialize tracing
    let env_filter = EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| EnvFilter::new("soul_relayer=info,warn"));

    match cli.log_format.as_str() {
        "json" => {
            fmt()
                .json()
                .with_env_filter(env_filter)
                .with_target(true)
                .init();
        }
        _ => {
            fmt()
                .with_env_filter(env_filter)
                .with_target(true)
                .init();
        }
    }

    info!("Loading config from {:?}", cli.config);

    let config_contents = match std::fs::read_to_string(&cli.config) {
        Ok(c) => c,
        Err(e) => {
            eprintln!(
                "Error: failed to read config file {:?}: {}",
                cli.config, e
            );
            std::process::exit(1);
        }
    };

    let config: RelayerConfig = match toml::from_str(&config_contents) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("Error: invalid config file: {}", e);
            std::process::exit(1);
        }
    };

    info!(
        chains = config.chains.len(),
        metrics_port = config.metrics_port,
        "Relayer daemon starting"
    );

    if let Err(e) = run_relayer(config).await {
        eprintln!("Relayer exited with error: {}", e);
        std::process::exit(1);
    }
}
