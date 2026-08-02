//! Nexus Core - High-performance Rust engine for the Nexus AI orchestrator.
//!
//! This crate provides the performance-critical components of Nexus:
//! - **crypto**: AES-GCM encryption, key derivation, secure messaging
//! - **mesh**: Mesh networking protocol with encrypted peer-to-peer communication
//! - **discovery**: mDNS device discovery and capability scanning
//! - **executor**: Task decomposition and distributed compute pooling
//! - **security**: Network monitoring, intrusion detection, data exfiltration prevention
//! - **ffi**: Python bindings via PyO3

pub mod crypto;
pub mod mesh;
pub mod discovery;
pub mod executor;
pub mod security;

#[cfg(feature = "python-bindings")]
pub mod ffi;

/// Nexus node identity - unique across the mesh network
pub type NodeId = String;

/// Capability score for a device (0.0 - 1.0, higher = more capable)
pub type CapabilityScore = f32;

/// Core Nexus version
pub const VERSION: &str = env!("CARGO_PKG_VERSION");
pub const PROTOCOL_VERSION: u16 = 1;
