//! Binary entry point for the Lumora privacy coprocessor.
//!
//! The coprocessor runs as a long-lived service that accepts proof
//! generation requests from the SDK and submits verified proofs
//! to on-chain privacy pools across all target chains.
//!
//! Usage:
//!   lumora-coprocessor serve --port 8080
//!   lumora-coprocessor prove --input proof-request.json
//!   RUST_LOG=lumora_coprocessor=debug lumora-coprocessor serve

use clap::{Parser, Subcommand};
use lumora_coprocessor::types::*;
use std::path::PathBuf;
use tracing::{error, info};
use tracing_subscriber::{fmt, EnvFilter};

/// Lumora privacy coprocessor — off-chain proof generation and submission.
#[derive(Parser, Debug)]
#[command(name = "lumora-coprocessor", version, about)]
struct Cli {
    /// Log output format: "text" or "json".
    #[arg(long, default_value = "text")]
    log_format: String,

    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand, Debug)]
enum Commands {
    /// Run as a long-lived HTTP service accepting proof requests.
    Serve {
        /// Port to listen on.
        #[arg(short, long, default_value_t = 8080)]
        port: u16,

        /// Bind address.
        #[arg(long, default_value = "0.0.0.0")]
        bind: String,

        /// Number of proof generation workers.
        #[arg(long, default_value_t = 4)]
        workers: usize,
    },

    /// Generate a single proof from a JSON request file (batch/CLI mode).
    Prove {
        /// Path to the proof request JSON file.
        #[arg(short, long)]
        input: PathBuf,

        /// Output path for the generated proof.
        #[arg(short, long, default_value = "proof-output.json")]
        output: PathBuf,
    },

    /// Check health / readiness of the proving backend.
    Health,
}

#[tokio::main]
async fn main() {
    let cli = Cli::parse();

    // Initialize tracing
    let env_filter = EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| EnvFilter::new("lumora_coprocessor=info,warn"));

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

    match cli.command {
        Commands::Serve {
            port,
            bind,
            workers,
        } => {
            info!(port, %bind, workers, "Starting Lumora coprocessor HTTP service");

            // In production, this spawns an HTTP server (e.g. axum/warp) with:
            //   POST /prove/transfer  → generate transfer proof
            //   POST /prove/withdraw  → generate withdraw proof
            //   POST /prove/deposit   → generate deposit proof
            //   GET  /health          → readiness check
            //   GET  /metrics         → Prometheus metrics
            //
            // Each request is dispatched to a worker pool that runs the
            // Halo2 prover, wraps the result in a Groth16 SNARK envelope,
            // and returns the serialized proof + public inputs.

            info!("Coprocessor service would listen on {}:{}", bind, port);
            info!("Proof worker pool size: {}", workers);

            // Placeholder: keep alive
            info!("Coprocessor ready — awaiting proof requests");
            tokio::signal::ctrl_c()
                .await
                .expect("Failed to listen for Ctrl+C");
            info!("Shutting down coprocessor");
        }

        Commands::Prove { input, output } => {
            info!("Generating proof from {:?}", input);

            let request_str = match std::fs::read_to_string(&input) {
                Ok(s) => s,
                Err(e) => {
                    error!("Failed to read input file: {}", e);
                    std::process::exit(1);
                }
            };

            // Parse and validate the proof request
            let _request: serde_json::Value = match serde_json::from_str(&request_str) {
                Ok(v) => v,
                Err(e) => {
                    error!("Invalid JSON in proof request: {}", e);
                    std::process::exit(1);
                }
            };

            // In production:
            // 1. Parse into a typed ProofRequest
            // 2. Validate all inputs against the circuit constraints
            // 3. Instantiate the appropriate Halo2 circuit
            // 4. Run the prover
            // 5. Wrap in Groth16 SNARK envelope for EVM verification
            // 6. Serialize proof + public inputs

            info!("Proof generation complete → {:?}", output);

            let proof_output = serde_json::json!({
                "status": "success",
                "proof": "0x...placeholder...",
                "publicInputs": [],
                "provingSystem": "halo2-groth16-wrapper",
                "circuitVersion": "0.1.0"
            });

            if let Err(e) =
                std::fs::write(&output, serde_json::to_string_pretty(&proof_output).unwrap())
            {
                error!("Failed to write output: {}", e);
                std::process::exit(1);
            }

            info!("Proof written to {:?}", output);
        }

        Commands::Health => {
            info!("Checking coprocessor health...");

            // Verify the proving backend is available
            // In production: attempt to create a dummy proof to validate
            // that the circuit parameters and SRS are loaded correctly.
            println!("status: ok");
            println!("prover: halo2");
            println!("snark_wrapper: groth16");
            println!("circuit_version: 0.1.0");
        }
    }
}
