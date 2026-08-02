//! Python bindings for the Nexus Rust core.
//!
//! Exposes key functionality to Python via PyO3:
//! - Cryptographic operations
//! - Device capability scanning
//! - Task decomposition

use pyo3::prelude::*;

use crate::crypto;
use crate::discovery;

/// Encrypt text using the Nexus AES-256-GCM protocol.
#[pyfunction]
fn encrypt_message(key_bytes: Vec<u8>, plaintext: &str) -> PyResult<Vec<u8>> {
    let key_arr: [u8; 32] = key_bytes
        .try_into()
        .map_err(|_| pyo3::exceptions::PyValueError::new_err("Key must be exactly 32 bytes"))?;
    let key = crypto::SymmetricKey::from_bytes(key_arr);
    crypto::encrypt(&key, plaintext.as_bytes())
        .map_err(|e| pyo3::exceptions::PyValueError::new_err(e.to_string()))
}

/// Decrypt text using the Nexus AES-256-GCM protocol.
#[pyfunction]
fn decrypt_message(key_bytes: Vec<u8>, cipher_data: Vec<u8>) -> PyResult<String> {
    let key_arr: [u8; 32] = key_bytes
        .try_into()
        .map_err(|_| pyo3::exceptions::PyValueError::new_err("Key must be exactly 32 bytes"))?;
    let key = crypto::SymmetricKey::from_bytes(key_arr);
    let plain = crypto::decrypt(&key, &cipher_data)
        .map_err(|e| pyo3::exceptions::PyValueError::new_err(e.to_string()))?;
    String::from_utf8(plain)
        .map_err(|e| pyo3::exceptions::PyValueError::new_err(e.to_string()))
}

/// Derive a key from a PIN and node ID.
#[pyfunction]
fn derive_key(pin: &str, node_id: &str) -> Vec<u8> {
    let salt = crypto::salt_for_node_id(node_id);
    let key = crypto::derive_key_from_pin(pin, &salt);
    key.as_bytes().to_vec()
}

/// Scan local device capabilities and return as a JSON string.
#[pyfunction]
fn scan_capabilities(node_id: &str, hostname: &str) -> PyResult<String> {
    let caps = discovery::scan_local_capabilities(node_id.to_string(), hostname.to_string());
    serde_json::to_string(&caps)
        .map_err(|e| pyo3::exceptions::PyValueError::new_err(e.to_string()))
}

#[pymodule]
#[pyo3(name = "_nexus_core")]
fn nexus_core_module(m: &Bound<'_, PyModule>) -> PyResult<()> {
    m.add_function(wrap_pyfunction!(encrypt_message, m)?)?;
    m.add_function(wrap_pyfunction!(decrypt_message, m)?)?;
    m.add_function(wrap_pyfunction!(derive_key, m)?)?;
    m.add_function(wrap_pyfunction!(scan_capabilities, m)?)?;
    m.add("__version__", env!("CARGO_PKG_VERSION"))?;
    m.add("PROTOCOL_VERSION", crate::PROTOCOL_VERSION)?;
    Ok(())
}
