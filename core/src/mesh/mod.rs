//! Mesh networking: secure peer-to-peer communication protocol.
//!
//! Provides encrypted message passing between Nexus nodes over TCP,
//! with support for MQTT bridging and WebSocket for remote access.
//!
//! Compatible with the existing Android/desktop mesh protocol:
//! - Encrypted MeshMessage JSON envelope
//! - AES-256-GCM authenticated encryption
//! - Peer trust store for key management

use std::collections::HashMap;
use std::sync::Arc;

use serde::{Deserialize, Serialize};
use tokio::sync::RwLock;

use crate::crypto::SymmetricKey;
use crate::NodeId;

// ---------------------------------------------------------------------------
// Message types (compatible with Android/desktop protocol)
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum MeshMessageType {
    Command,
    Query,
    Context,
    PairingRequest,
    PairingResponse,
    Result,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MeshMessage {
    pub sender_id: NodeId,
    #[serde(rename = "type")]
    pub msg_type: MeshMessageType,
    pub iv: String,       // base64-encoded nonce
    pub payload: String,  // base64-encoded ciphertext + tag
    pub timestamp: u64,   // milliseconds since epoch
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MeshPayload {
    pub command: Option<String>,
    pub context: Option<String>,
    pub result: Option<String>,
    pub success: bool,
}

// ---------------------------------------------------------------------------
// Transport types
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub enum TransportType {
    Ble,
    WifiNsd,
    Mqtt,
    WebSocket,
}

// ---------------------------------------------------------------------------
// Mesh node (peer)
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MeshNode {
    pub id: NodeId,
    pub name: String,
    pub address: String,
    pub port: Option<u16>,
    pub transport: TransportType,
    pub last_seen: u64,   // milliseconds
    pub is_paired: bool,
}

impl MeshNode {
    pub fn is_reachable(&self) -> bool {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis() as u64;
        (now - self.last_seen) < 60_000
    }
}

// ---------------------------------------------------------------------------
// Peer trust store
// ---------------------------------------------------------------------------

/// Manages trusted peer identities and shared AES keys.
pub struct PeerTrustStore {
    store: RwLock<HashMap<NodeId, (SymmetricKey, bool)>>, // (key, is_paired)
}

impl PeerTrustStore {
    pub fn new() -> Self {
        Self {
            store: RwLock::new(HashMap::new()),
        }
    }

    pub async fn store_peer_key(&self, peer_id: &NodeId, key: SymmetricKey) {
        let mut store = self.store.write().await;
        store.insert(peer_id.clone(), (key, true));
    }

    pub async fn get_peer_key(&self, peer_id: &NodeId) -> Option<SymmetricKey> {
        let store = self.store.read().await;
        store.get(peer_id).map(|(k, _)| k.clone())
    }

    pub async fn is_paired(&self, peer_id: &NodeId) -> bool {
        let store = self.store.read().await;
        store.get(peer_id).map(|(_, p)| *p).unwrap_or(false)
    }

    pub async fn remove_peer(&self, peer_id: &NodeId) {
        let mut store = self.store.write().await;
        store.remove(peer_id);
    }

    pub async fn list_paired_peer_ids(&self) -> Vec<NodeId> {
        let store = self.store.read().await;
        store
            .iter()
            .filter(|(_, (_, p))| *p)
            .map(|(id, _)| id.clone())
            .collect()
    }
}

impl Default for PeerTrustStore {
    fn default() -> Self {
        Self::new()
    }
}

impl MeshMessage {
    /// Create a new encrypted mesh message.
    pub fn new(
        sender_id: NodeId,
        msg_type: MeshMessageType,
        iv: Vec<u8>,
        payload: Vec<u8>,
    ) -> Self {
        use base64::Engine;
        Self {
            sender_id,
            msg_type,
            iv: base64::engine::general_purpose::STANDARD.encode(&iv),
            payload: base64::engine::general_purpose::STANDARD.encode(&payload),
            timestamp: std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap_or_default()
                .as_millis() as u64,
        }
    }

    pub fn decode_iv(&self) -> Result<Vec<u8>, crate::crypto::CryptoError> {
        use base64::Engine;
        base64::engine::general_purpose::STANDARD
            .decode(&self.iv)
            .map_err(|_| crate::crypto::CryptoError::Base64DecodeFailed)
    }

    pub fn decode_payload(&self) -> Result<Vec<u8>, crate::crypto::CryptoError> {
        use base64::Engine;
        base64::engine::general_purpose::STANDARD
            .decode(&self.payload)
            .map_err(|_| crate::crypto::CryptoError::Base64DecodeFailed)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::crypto::{encrypt, SymmetricKey};

    #[test]
    fn test_mesh_message_roundtrip() {
        let key = SymmetricKey(rand::random());
        let payload = MeshPayload {
            command: Some("GET_TIME_DATE".into()),
            context: None,
            result: None,
            success: true,
        };
        let payload_json = serde_json::to_string(&payload).unwrap();
        let encrypted = encrypt(&key, payload_json.as_bytes()).unwrap();
        let (iv, ct) = encrypted.split_at(12);
        let msg = MeshMessage::new(
            "test-node-1".into(),
            MeshMessageType::Command,
            iv.to_vec(),
            ct.to_vec(),
        );
        assert_eq!(msg.sender_id, "test-node-1");
        assert_eq!(msg.msg_type, MeshMessageType::Command);
        assert!(!msg.iv.is_empty());
        assert!(!msg.payload.is_empty());
    }
}
