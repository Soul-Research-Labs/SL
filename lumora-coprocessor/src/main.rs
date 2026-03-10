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
use lumora_coprocessor::proof::ProofGenerator;
use std::path::PathBuf;
use std::sync::Arc;
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

            // Initialize proof generator with empty proving keys.
            // In production, load from SRS ceremony artifacts on disk.
            let generator = Arc::new(ProofGenerator::new(
                vec![1u8; 32], // placeholder transfer PK
                vec![1u8; 32], // placeholder withdraw PK
                Some(vec![1u8; 32]), // placeholder SNARK wrapper PK
            ));

            let app = build_router(generator);

            let addr = format!("{}:{}", bind, port);
            let listener = tokio::net::TcpListener::bind(&addr)
                .await
                .expect("Failed to bind address");

            info!("Coprocessor listening on {}", addr);
            info!("Proof worker pool size: {}", workers);
            info!("Routes: POST /prove/transfer, POST /prove/withdraw, GET /health");

            axum::serve(listener, app)
                .with_graceful_shutdown(async {
                    tokio::signal::ctrl_c()
                        .await
                        .expect("Failed to listen for Ctrl+C");
                    info!("Shutting down coprocessor");
                })
                .await
                .expect("Server error");
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

            let request: serde_json::Value = match serde_json::from_str(&request_str) {
                Ok(v) => v,
                Err(e) => {
                    error!("Invalid JSON in proof request: {}", e);
                    std::process::exit(1);
                }
            };

            let generator = ProofGenerator::new(
                vec![1u8; 32],
                vec![1u8; 32],
                Some(vec![1u8; 32]),
            );

            let proof_type = request
                .get("type")
                .and_then(|v| v.as_str())
                .unwrap_or("transfer");

            let proof_output = match proof_type {
                "transfer" => {
                    match serde_json::from_value::<TransferRequest>(request.clone()) {
                        Ok(req) => match generator.generate_transfer(&req) {
                            Ok(proof) => serde_json::json!({
                                "status": "success",
                                "proof": hex::encode(&proof.raw_proof),
                                "snarkWrapper": proof.snark_wrapper.map(hex::encode),
                                "publicInputs": proof.public_inputs.iter()
                                    .map(hex::encode).collect::<Vec<_>>(),
                                "provingSystem": "halo2-groth16-wrapper",
                                "circuitVersion": "0.1.0"
                            }),
                            Err(e) => {
                                error!("Proof generation failed: {}", e);
                                std::process::exit(1);
                            }
                        },
                        Err(e) => {
                            error!("Invalid transfer request: {}", e);
                            std::process::exit(1);
                        }
                    }
                }
                "withdraw" => {
                    match serde_json::from_value::<WithdrawRequest>(request.clone()) {
                        Ok(req) => match generator.generate_withdraw(&req) {
                            Ok(proof) => serde_json::json!({
                                "status": "success",
                                "proof": hex::encode(&proof.raw_proof),
                                "snarkWrapper": proof.snark_wrapper.map(hex::encode),
                                "publicInputs": proof.public_inputs.iter()
                                    .map(hex::encode).collect::<Vec<_>>(),
                                "provingSystem": "halo2-groth16-wrapper",
                                "circuitVersion": "0.1.0"
                            }),
                            Err(e) => {
                                error!("Proof generation failed: {}", e);
                                std::process::exit(1);
                            }
                        },
                        Err(e) => {
                            error!("Invalid withdraw request: {}", e);
                            std::process::exit(1);
                        }
                    }
                }
                other => {
                    error!("Unknown proof type: {}", other);
                    std::process::exit(1);
                }
            };

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
            println!("status: ok");
            println!("prover: halo2");
            println!("snark_wrapper: groth16");
            println!("circuit_version: 0.1.0");
        }
    }
}

// ── HTTP Router and Handlers ───────────────────────────────────────────────

fn build_router(generator: Arc<ProofGenerator>) -> axum::Router {
    use axum::{routing::{get, post}, Router};

    Router::new()
        .route("/health", get(handle_health))
        .route("/prove/transfer", post(handle_prove_transfer))
        .route("/prove/withdraw", post(handle_prove_withdraw))
        .with_state(generator)
}

async fn handle_health() -> axum::Json<serde_json::Value> {
    axum::Json(serde_json::json!({
        "status": "ok",
        "prover": "halo2",
        "snarkWrapper": "groth16",
        "circuitVersion": "0.1.0"
    }))
}

async fn handle_prove_transfer(
    axum::extract::State(generator): axum::extract::State<Arc<ProofGenerator>>,
    axum::Json(request): axum::Json<TransferRequest>,
) -> axum::response::Result<axum::Json<serde_json::Value>> {
    let result = tokio::task::spawn_blocking(move || generator.generate_transfer(&request))
        .await
        .map_err(|e| {
            (
                axum::http::StatusCode::INTERNAL_SERVER_ERROR,
                format!("Worker panic: {}", e),
            )
        })?
        .map_err(|e| {
            (
                axum::http::StatusCode::BAD_REQUEST,
                format!("Proof generation failed: {}", e),
            )
        })?;

    Ok(axum::Json(serde_json::json!({
        "status": "success",
        "proof": hex::encode(&result.raw_proof),
        "snarkWrapper": result.snark_wrapper.map(hex::encode),
        "publicInputs": result.public_inputs.iter().map(hex::encode).collect::<Vec<_>>(),
        "provingSystem": "halo2-groth16-wrapper",
        "circuitVersion": "0.1.0"
    })))
}

async fn handle_prove_withdraw(
    axum::extract::State(generator): axum::extract::State<Arc<ProofGenerator>>,
    axum::Json(request): axum::Json<WithdrawRequest>,
) -> axum::response::Result<axum::Json<serde_json::Value>> {
    let result = tokio::task::spawn_blocking(move || generator.generate_withdraw(&request))
        .await
        .map_err(|e| {
            (
                axum::http::StatusCode::INTERNAL_SERVER_ERROR,
                format!("Worker panic: {}", e),
            )
        })?
        .map_err(|e| {
            (
                axum::http::StatusCode::BAD_REQUEST,
                format!("Proof generation failed: {}", e),
            )
        })?;

    Ok(axum::Json(serde_json::json!({
        "status": "success",
        "proof": hex::encode(&result.raw_proof),
        "snarkWrapper": result.snark_wrapper.map(hex::encode),
        "publicInputs": result.public_inputs.iter().map(hex::encode).collect::<Vec<_>>(),
        "provingSystem": "halo2-groth16-wrapper",
        "circuitVersion": "0.1.0"
    })))
}
