//! Health and readiness endpoint for the relayer daemon.
//!
//! Serves JSON health responses on a configurable HTTP endpoint,
//! alongside the existing Prometheus metrics endpoint.
//!
//! Endpoints:
//!   GET /health   → { "status": "ok", "uptime_secs": ..., "chains": ..., "version": "0.2.0" }
//!   GET /metrics  → Prometheus text exposition format
//!   GET /ready    → 200 if all watched chains are connected, 503 otherwise

use crate::config::RelayerConfig;
use crate::metrics::Metrics;
use std::net::SocketAddr;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Instant;
use tokio::net::TcpListener;
use tracing::{error, info};

/// Health state shared across watchers and the HTTP handler.
#[derive(Debug)]
pub struct HealthState {
    /// Startup instant for uptime calculation.
    started_at: Instant,
    /// Number of chains the relayer is configured to watch.
    pub configured_chains: u64,
    /// Number of chains currently connected (updated by watchers).
    pub connected_chains: AtomicU64,
    /// Whether the relayer considers itself ready.
    pub ready: AtomicBool,
    /// Last successful relay timestamp (unix epoch seconds).
    pub last_relay_timestamp: AtomicU64,
}

impl HealthState {
    pub fn new(configured_chains: u64) -> Self {
        Self {
            started_at: Instant::now(),
            configured_chains,
            connected_chains: AtomicU64::new(0),
            ready: AtomicBool::new(false),
            last_relay_timestamp: AtomicU64::new(0),
        }
    }

    pub fn uptime_secs(&self) -> u64 {
        self.started_at.elapsed().as_secs()
    }

    pub fn mark_chain_connected(&self) {
        let prev = self.connected_chains.fetch_add(1, Ordering::Relaxed);
        if prev + 1 >= self.configured_chains {
            self.ready.store(true, Ordering::Relaxed);
        }
    }

    pub fn mark_chain_disconnected(&self) {
        let prev = self.connected_chains.fetch_sub(1, Ordering::Relaxed);
        if prev <= self.configured_chains {
            self.ready.store(false, Ordering::Relaxed);
        }
    }

    pub fn record_relay(&self, timestamp: u64) {
        self.last_relay_timestamp.store(timestamp, Ordering::Relaxed);
    }

    /// Render JSON health response.
    pub fn render_health(&self) -> String {
        let status = if self.ready.load(Ordering::Relaxed) {
            "ok"
        } else {
            "starting"
        };

        format!(
            r#"{{"status":"{}","uptime_secs":{},"configured_chains":{},"connected_chains":{},"last_relay_ts":{},"version":"0.2.0"}}"#,
            status,
            self.uptime_secs(),
            self.configured_chains,
            self.connected_chains.load(Ordering::Relaxed),
            self.last_relay_timestamp.load(Ordering::Relaxed),
        )
    }
}

/// Spawn the combined health + metrics HTTP server.
///
/// Route dispatching:
///   /health  → JSON health payload
///   /ready   → 200 OK / 503 Service Unavailable
///   /metrics → Prometheus text format
///   *        → 404
pub async fn serve_health(
    metrics: Arc<Metrics>,
    health: Arc<HealthState>,
    addr: SocketAddr,
) {
    let listener = match TcpListener::bind(addr).await {
        Ok(l) => l,
        Err(e) => {
            error!("Failed to bind health server on {}: {}", addr, e);
            return;
        }
    };
    info!("Health + metrics server listening on {}", addr);

    loop {
        let (stream, _) = match listener.accept().await {
            Ok(conn) => conn,
            Err(e) => {
                error!("Health server accept error: {}", e);
                continue;
            }
        };

        let metrics = metrics.clone();
        let health = health.clone();

        tokio::spawn(async move {
            use tokio::io::{AsyncReadExt, AsyncWriteExt};
            let mut stream = stream;

            // Read the HTTP request (first line is enough for routing)
            let mut buf = vec![0u8; 1024];
            let n = match stream.read(&mut buf).await {
                Ok(n) if n > 0 => n,
                _ => return,
            };

            let request = String::from_utf8_lossy(&buf[..n]);
            let first_line = request.lines().next().unwrap_or("");

            let (status_code, content_type, body) = if first_line.starts_with("GET /health") {
                let body = health.render_health();
                ("200 OK", "application/json", body)
            } else if first_line.starts_with("GET /ready") {
                if health.ready.load(Ordering::Relaxed) {
                    ("200 OK".to_string(), "text/plain", "ready".to_string())
                } else {
                    (
                        "503 Service Unavailable".to_string(),
                        "text/plain",
                        "not ready".to_string(),
                    )
                }
            } else if first_line.starts_with("GET /metrics") {
                let body = metrics.render();
                ("200 OK", "text/plain; version=0.0.4", body)
            } else {
                ("404 Not Found", "text/plain", "not found".to_string())
            };

            let response = format!(
                "HTTP/1.1 {}\r\nContent-Type: {}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                status_code,
                content_type,
                body.len(),
                body
            );

            let _ = stream.write_all(response.as_bytes()).await;
            let _ = stream.shutdown().await;
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn health_state_uptime() {
        let h = HealthState::new(3);
        assert!(h.uptime_secs() < 2); // just created
    }

    #[test]
    fn health_state_ready_when_all_chains_connected() {
        let h = HealthState::new(2);
        assert!(!h.ready.load(Ordering::Relaxed));

        h.mark_chain_connected();
        assert!(!h.ready.load(Ordering::Relaxed)); // 1 of 2

        h.mark_chain_connected();
        assert!(h.ready.load(Ordering::Relaxed)); // 2 of 2
    }

    #[test]
    fn health_render_contains_status() {
        let h = HealthState::new(1);
        let json = h.render_health();
        assert!(json.contains("\"status\":\"starting\""));

        h.mark_chain_connected();
        let json = h.render_health();
        assert!(json.contains("\"status\":\"ok\""));
    }

    #[test]
    fn health_record_relay() {
        let h = HealthState::new(1);
        h.record_relay(1700000000);
        assert_eq!(h.last_relay_timestamp.load(Ordering::Relaxed), 1700000000);
    }
}
