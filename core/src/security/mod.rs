//! Network security, intrusion detection, and data exfiltration prevention.
//!
//! Implements the "Zero-Knowledge Proofing" principle:
//! - Monitors network traffic for unauthorized data exfiltration
//! - Blocks suspicious outbound connections
//! - Provides a dynamic, self-updating threat model

use serde::{Deserialize, Serialize};
use std::collections::{HashMap, VecDeque};

// ---------------------------------------------------------------------------
// Threat model
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, PartialOrd, Ord)]
#[serde(rename_all = "snake_case")]
pub enum ThreatLevel {
    Safe,
    Suspicious,
    Dangerous,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ThreatAlert {
    pub level: ThreatLevel,
    pub source: String,
    pub description: String,
    pub timestamp: u64,
    pub blocked: bool,
}

// ---------------------------------------------------------------------------
// Network traffic monitor
// ---------------------------------------------------------------------------

/// Represents a single outbound network connection attempt.
#[derive(Debug, Clone)]
pub struct ConnectionAttempt {
    pub source_ip: String,
    pub source_port: u16,
    pub dest_ip: String,
    pub dest_port: u16,
    pub protocol: String,
    pub bytes_sent: u64,
    pub timestamp: u64,
}

/// Configuration for the security guard.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SecurityConfig {
    /// Allowed outbound destinations (IPs, domains, or CIDR ranges)
    pub allowlist: Vec<String>,
    /// Blocked outbound destinations
    pub blocklist: Vec<String>,
    /// Maximum bytes per second before triggering a data exfiltration alert
    pub max_bytes_per_second: u64,
    /// Number of failed connection attempts before blocking a source
    pub max_failed_attempts: u32,
    /// Whether to automatically block threats
    pub auto_block: bool,
}

impl Default for SecurityConfig {
    fn default() -> Self {
        Self {
            allowlist: vec![
                "localhost".into(),
                "127.0.0.0/8".into(),
                "192.168.0.0/16".into(),
                "10.0.0.0/8".into(),
                "172.16.0.0/12".into(),
            ],
            blocklist: Vec::new(),
            max_bytes_per_second: 1024 * 1024, // 1 MB/s
            max_failed_attempts: 10,
            auto_block: true,
        }
    }
}

// ---------------------------------------------------------------------------
// Security Guard
// ---------------------------------------------------------------------------

/// The main security guard that monitors and protects the Nexus ecosystem.
pub struct SecurityGuard {
    config: SecurityConfig,
    alerts: VecDeque<ThreatAlert>,
    connection_history: VecDeque<ConnectionAttempt>,
    blocked_ips: HashMap<String, u64>, // IP → blocked until timestamp

    /// Number of times each IP has attempted blocked/blocklisted connections.
    #[allow(dead_code)]
    failed_attempts: HashMap<String, u32>,
}

impl SecurityGuard {
    pub fn new(config: SecurityConfig) -> Self {
        Self {
            config,
            alerts: VecDeque::with_capacity(256),
            connection_history: VecDeque::with_capacity(1024),
            blocked_ips: HashMap::new(),
            failed_attempts: HashMap::new(),
        }
    }

    /// Evaluate a connection attempt for threats.
    pub fn evaluate_connection(&mut self, conn: ConnectionAttempt) -> Option<ThreatAlert> {
        // Check if IP is already blocked
        if let Some(&blocked_until) = self.blocked_ips.get(&conn.dest_ip) {
            let now = now_ms();
            if now < blocked_until {
                return Some(ThreatAlert {
                    level: ThreatLevel::Dangerous,
                    source: conn.dest_ip.clone(),
                    description: format!("Blocked connection to {}", conn.dest_ip),
                    timestamp: now,
                    blocked: true,
                });
            }
            // Unblock expired entries
            self.blocked_ips.remove(&conn.dest_ip);
        }

        // Check against blocklist
        if self.is_blocked(&conn.dest_ip) {
            if self.config.auto_block {
                self.block_ip(&conn.dest_ip, 3600); // block for 1 hour
            }
            let alert = ThreatAlert {
                level: ThreatLevel::Dangerous,
                source: conn.dest_ip.clone(),
                description: format!("Connection to blocked destination: {}", conn.dest_ip),
                timestamp: now_ms(),
                blocked: self.config.auto_block,
            };
            self.alerts.push_back(alert.clone());
            return Some(alert);
        }

        // Check for data exfiltration (high-volume outbound)
        if self.is_exfiltration_pattern(&conn) {
            let alert = ThreatAlert {
                level: ThreatLevel::Dangerous,
                source: conn.dest_ip.clone(),
                description: format!(
                    "Potential data exfiltration: {} bytes sent to {}",
                    conn.bytes_sent, conn.dest_ip
                ),
                timestamp: now_ms(),
                blocked: self.config.auto_block,
            };
            if self.config.auto_block {
                self.block_ip(&conn.dest_ip, 7200); // block for 2 hours
            }
            self.alerts.push_back(alert.clone());
            return Some(alert);
        }

        // Record the connection
        self.connection_history.push_back(conn);
        while self.connection_history.len() > 1024 {
            self.connection_history.pop_front();
        }

        None
    }

    /// Check if an IP is in the blocklist.
    fn is_blocked(&self, ip: &str) -> bool {
        self.config.blocklist.iter().any(|blocked| {
            if blocked.contains('/') {
                // CIDR matching (simplified)
                ip_matches_cidr(ip, blocked)
            } else {
                blocked == ip
            }
        })
    }

    /// Detect potential data exfiltration patterns.
    fn is_exfiltration_pattern(&self, conn: &ConnectionAttempt) -> bool {
        // Check if destination is outside the allowlist
        let is_external = !self.config.allowlist.iter().any(|allowed| {
            if allowed.contains('/') {
                ip_matches_cidr(&conn.dest_ip, allowed)
            } else if *allowed == "localhost" {
                conn.dest_ip == "127.0.0.1" || conn.dest_ip == "::1"
            } else {
                *allowed == conn.dest_ip
            }
        });

        if !is_external {
            return false;
        }

        // Check high-volume upload
        if conn.bytes_sent > self.config.max_bytes_per_second {
            return true;
        }

        // Check burst pattern: many connections in a short time
        let one_second_ago = now_ms().saturating_sub(1000);
        let recent_connections: Vec<_> = self
            .connection_history
            .iter()
            .filter(|c| c.timestamp > one_second_ago && c.dest_ip == conn.dest_ip)
            .collect();

        if recent_connections.len() > 5 {
            return true;
        }

        false
    }

    /// Block an IP address.
    fn block_ip(&mut self, ip: &str, duration_seconds: u64) {
        let until = now_ms() + duration_seconds * 1000;
        self.blocked_ips.insert(ip.to_string(), until);
    }

    /// Get recent threat alerts.
    pub fn get_alerts(&self, max_count: usize) -> Vec<ThreatAlert> {
        self.alerts
            .iter()
            .rev()
            .take(max_count)
            .cloned()
            .collect()
    }

    /// Clear all alerts.
    pub fn clear_alerts(&mut self) {
        self.alerts.clear();
    }

    /// Add an IP to the blocklist.
    pub fn add_to_blocklist(&mut self, ip: String) {
        if !self.config.blocklist.contains(&ip) {
            self.config.blocklist.push(ip);
        }
    }

    /// Remove an IP from the blocklist.
    pub fn remove_from_blocklist(&mut self, ip: &str) {
        self.config.blocklist.retain(|b| b != ip);
    }
}

/// Simplified CIDR matching.
fn ip_matches_cidr(ip: &str, cidr: &str) -> bool {
    if cidr == "localhost" && (ip == "127.0.0.1" || ip == "::1") {
        return true;
    }
    // For internal ranges, check prefix
    match cidr {
        "192.168.0.0/16" => ip.starts_with("192.168."),
        "10.0.0.0/8" => ip.starts_with("10."),
        "172.16.0.0/12" => {
            if let Some(second) = ip.split('.').nth(1) {
                if let Ok(num) = second.parse::<u32>() {
                    (16..=31).contains(&num) && ip.starts_with("172.")
                } else {
                    false
                }
            } else {
                false
            }
        }
        "127.0.0.0/8" => ip.starts_with("127."),
        _ => ip == cidr, // fallback to exact match
    }
}

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_block_external_connection() {
        let config = SecurityConfig::default();
        let mut guard = SecurityGuard::new(config);

        let conn = ConnectionAttempt {
            source_ip: "192.168.1.100".into(),
            source_port: 54321,
            dest_ip: "8.8.8.8".into(),
            dest_port: 443,
            protocol: "tcp".into(),
            bytes_sent: 10 * 1024 * 1024, // 10 MB (exceeds 1 MB/s)
            timestamp: now_ms(),
        };

        let alert = guard.evaluate_connection(conn);
        assert!(alert.is_some());
        assert_eq!(alert.unwrap().level, ThreatLevel::Dangerous);
    }

    #[test]
    fn test_allow_local_connection() {
        let config = SecurityConfig::default();
        let mut guard = SecurityGuard::new(config);

        let conn = ConnectionAttempt {
            source_ip: "192.168.1.100".into(),
            source_port: 54321,
            dest_ip: "192.168.1.5".into(),
            dest_port: 9090,
            protocol: "tcp".into(),
            bytes_sent: 1024,
            timestamp: now_ms(),
        };

        let alert = guard.evaluate_connection(conn);
        assert!(alert.is_none());
    }

    #[test]
    fn test_ip_blocklist() {
        let mut config = SecurityConfig::default();
        config.blocklist.push("203.0.113.0".into());
        let mut guard = SecurityGuard::new(config);

        let conn = ConnectionAttempt {
            source_ip: "192.168.1.100".into(),
            source_port: 54321,
            dest_ip: "203.0.113.0".into(),
            dest_port: 443,
            protocol: "tcp".into(),
            bytes_sent: 100,
            timestamp: now_ms(),
        };

        let alert = guard.evaluate_connection(conn);
        assert!(alert.is_some());
    }
}
