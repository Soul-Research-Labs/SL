//! Prometheus metrics for the cross-chain privacy relayer.
//!
//! Exposes a `/metrics` HTTP endpoint for Prometheus scraping.

use std::net::SocketAddr;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use tokio::net::TcpListener;
use tracing::{error, info};

/// Relayer metrics counters.
#[derive(Debug, Default)]
pub struct Metrics {
    /// Total EpochFinalized events received across all chains.
    pub epochs_received: AtomicU64,
    /// Total relay commands dispatched.
    pub relays_dispatched: AtomicU64,
    /// Total relay failures.
    pub relay_failures: AtomicU64,
    /// Total registry submissions.
    pub registry_submissions: AtomicU64,
    /// Per-chain epoch counters (best-effort; keyed by chain_id offset).
    chain_epochs: [AtomicU64; 16],
}

impl Metrics {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn inc_epochs_received(&self) {
        self.epochs_received.fetch_add(1, Ordering::Relaxed);
    }

    pub fn inc_relays_dispatched(&self) {
        self.relays_dispatched.fetch_add(1, Ordering::Relaxed);
    }

    pub fn inc_relay_failures(&self) {
        self.relay_failures.fetch_add(1, Ordering::Relaxed);
    }

    pub fn inc_registry_submissions(&self) {
        self.registry_submissions.fetch_add(1, Ordering::Relaxed);
    }

    pub fn inc_chain_epoch(&self, chain_index: usize) {
        if chain_index < self.chain_epochs.len() {
            self.chain_epochs[chain_index].fetch_add(1, Ordering::Relaxed);
        }
    }

    /// Render metrics in Prometheus text exposition format.
    pub fn render(&self) -> String {
        let mut out = String::with_capacity(1024);

        out.push_str("# HELP relayer_epochs_received_total Total EpochFinalized events received.\n");
        out.push_str("# TYPE relayer_epochs_received_total counter\n");
        out.push_str(&format!(
            "relayer_epochs_received_total {}\n",
            self.epochs_received.load(Ordering::Relaxed)
        ));

        out.push_str("# HELP relayer_relays_dispatched_total Total relay commands dispatched.\n");
        out.push_str("# TYPE relayer_relays_dispatched_total counter\n");
        out.push_str(&format!(
            "relayer_relays_dispatched_total {}\n",
            self.relays_dispatched.load(Ordering::Relaxed)
        ));

        out.push_str("# HELP relayer_relay_failures_total Total relay failures.\n");
        out.push_str("# TYPE relayer_relay_failures_total counter\n");
        out.push_str(&format!(
            "relayer_relay_failures_total {}\n",
            self.relay_failures.load(Ordering::Relaxed)
        ));

        out.push_str(
            "# HELP relayer_registry_submissions_total Total registry submissions.\n",
        );
        out.push_str("# TYPE relayer_registry_submissions_total counter\n");
        out.push_str(&format!(
            "relayer_registry_submissions_total {}\n",
            self.registry_submissions.load(Ordering::Relaxed)
        ));

        for (i, counter) in self.chain_epochs.iter().enumerate() {
            let val = counter.load(Ordering::Relaxed);
            if val > 0 {
                out.push_str(&format!(
                    "relayer_chain_epochs_total{{chain_index=\"{}\"}} {}\n",
                    i, val
                ));
            }
        }

        out
    }
}

/// Spawn the Prometheus metrics HTTP server.
pub async fn serve_metrics(metrics: Arc<Metrics>, addr: SocketAddr) {
    let listener = match TcpListener::bind(addr).await {
        Ok(l) => l,
        Err(e) => {
            error!("Failed to bind metrics server on {}: {}", addr, e);
            return;
        }
    };
    info!("Metrics server listening on {}", addr);

    loop {
        let (stream, _) = match listener.accept().await {
            Ok(conn) => conn,
            Err(e) => {
                error!("Metrics accept error: {}", e);
                continue;
            }
        };

        let body = metrics.render();
        let response = format!(
            "HTTP/1.1 200 OK\r\nContent-Type: text/plain; version=0.0.4\r\nContent-Length: {}\r\n\r\n{}",
            body.len(),
            body
        );

        // Write response.
        use tokio::io::AsyncWriteExt;
        let mut stream = stream;
        let _ = stream.write_all(response.as_bytes()).await;
        let _ = stream.shutdown().await;
    }
}
