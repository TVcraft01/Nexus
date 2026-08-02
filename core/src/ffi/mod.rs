//! Python bindings for the Nexus Rust core.
//!
//! Exposes key functionality to Python via PyO3:
//! - Cryptographic operations
//! - Device capability scanning
//! - Task decomposition and distributed execution

use pyo3::prelude::*;

use std::cell::RefCell;
use std::ffi::{CStr, CString};
use std::os::raw::c_char;

use crate::crypto;
use crate::discovery;
use crate::executor;

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

// ---------------------------------------------------------------------------
// Executor / Task Distribution FFI (PyO3)
// ---------------------------------------------------------------------------

/// Analyze execution strategy for a workload given available devices (JSON).
#[pyfunction]
fn exec_analyze_strategy(workload_type: &str, devices_json: &str) -> PyResult<String> {
    exec_analyze_strategy_impl(workload_type, devices_json)
        .map_err(|e| pyo3::exceptions::PyValueError::new_err(e))
}

/// Decompose a task into sub-tasks based on available devices (JSON).
#[pyfunction]
fn exec_decompose(
    task_id: &str,
    description: &str,
    workload_type: &str,
    devices_json: &str,
) -> PyResult<String> {
    exec_decompose_impl(task_id, description, workload_type, devices_json)
        .map_err(|e| pyo3::exceptions::PyValueError::new_err(e))
}

/// Find device IDs capable of handling a workload (JSON).
#[pyfunction]
fn exec_find_capable_devices(workload_type: &str, devices_json: &str) -> PyResult<String> {
    exec_find_capable_devices_impl(workload_type, devices_json)
        .map_err(|e| pyo3::exceptions::PyValueError::new_err(e))
}

// ---- Helpers ----

fn parse_workload_type(s: &str) -> PyResult<executor::WorkloadType> {
    match s.to_lowercase().as_str() {
        "compute" => Ok(executor::WorkloadType::Compute),
        "gpu_compute" | "gpucompute" => Ok(executor::WorkloadType::GpuCompute),
        "io" => Ok(executor::WorkloadType::Io),
        "mixed" => Ok(executor::WorkloadType::Mixed),
        "command" => Ok(executor::WorkloadType::Command),
        other => Err(pyo3::exceptions::PyValueError::new_err(
            format!("Unknown workload type: {}", other)
        )),
    }
}

fn parse_devices(json: &str) -> PyResult<Vec<discovery::DiscoveredDevice>> {
    let values: Vec<serde_json::Value> = serde_json::from_str(json)
        .map_err(|e| pyo3::exceptions::PyValueError::new_err(
            format!("Invalid devices JSON: {}", e)
        ))?;

    // Gracefully skip individual devices that fail to parse rather than
    // failing the entire batch. Unknown device classes, missing fields,
    // etc. on one device shouldn't break scheduling for all devices.
    Ok(values
        .into_iter()
        .filter_map(|v| {
            match serde_json::from_value::<discovery::DeviceCapabilities>(v) {
                Ok(caps) => Some(discovery::DiscoveredDevice {
                    capabilities: caps,
                    address: "unknown".into(),
                    port: 9090,
                    last_seen: 0,
                    paired: true,
                }),
                Err(_) => None,
            }
        })
        .collect())
}

// ---------------------------------------------------------------------------
// C ABI exports (for ctypes access from Python bridge)
// ---------------------------------------------------------------------------
//
// Instead of heap-allocating return strings (which causes allocator mismatch
// crashes when Python tries to free them), we write results into a thread-local
// static buffer. Python holds the GIL during ctypes calls, so only one call per
// thread is in-flight at a time — this is always safe.

thread_local! {
    /// Thread-local buffer for C ABI return strings. Each call overwrites
    /// the previous result. The pointer remains valid until the next call
    /// on this thread or until the thread exits.
    static RESULT_BUF: RefCell<CString> = RefCell::new(CString::new("").unwrap());
}

/// Write a result string into the thread-local buffer and return a raw
/// pointer to it. The pointer is valid until the next call on this thread.
fn set_result(s: String) -> *mut c_char {
    RESULT_BUF.with(|buf| {
        *buf.borrow_mut() = CString::new(s).unwrap_or_else(|_| CString::new("{}").unwrap());
        buf.borrow().as_ptr() as *mut c_char
    })
}

/// Read a C string from a raw pointer. Safe because Python holds the GIL
/// during ctypes calls, keeping the source string alive.
unsafe fn read_c_str(ptr: *const c_char) -> String {
    if ptr.is_null() {
        return String::new();
    }
    CStr::from_ptr(ptr).to_string_lossy().into_owned()
}

/// No-op free function preserved for backward compatibility.
/// The thread-local buffer is automatically managed — no explicit free is needed.
#[no_mangle]
pub extern "C" fn nexus_free_string(_ptr: *mut c_char) {}

#[no_mangle]
pub extern "C" fn nexus_exec_analyze_strategy(
    workload_type: *const c_char,
    devices_json: *const c_char,
) -> *mut c_char {
    let wl_str = unsafe { read_c_str(workload_type) };
    let dev_str = unsafe { read_c_str(devices_json) };

    match exec_analyze_strategy_impl(&wl_str, &dev_str) {
        Ok(result) => set_result(result),
        Err(_) => set_result(r#"{"strategy":"local","target_node":null}"#.into()),
    }
}

#[no_mangle]
pub extern "C" fn nexus_exec_decompose(
    task_id: *const c_char,
    description: *const c_char,
    workload_type: *const c_char,
    devices_json: *const c_char,
) -> *mut c_char {
    let tid = unsafe { read_c_str(task_id) };
    let desc = unsafe { read_c_str(description) };
    let wl_str = unsafe { read_c_str(workload_type) };
    let dev_str = unsafe { read_c_str(devices_json) };

    match exec_decompose_impl(&tid, &desc, &wl_str, &dev_str) {
        Ok(result) => set_result(result),
        Err(_) => set_result("[]".into()),
    }
}

#[no_mangle]
pub extern "C" fn nexus_exec_find_capable_devices(
    workload_type: *const c_char,
    devices_json: *const c_char,
) -> *mut c_char {
    let wl_str = unsafe { read_c_str(workload_type) };
    let dev_str = unsafe { read_c_str(devices_json) };

    match exec_find_capable_devices_impl(&wl_str, &dev_str) {
        Ok(result) => set_result(result),
        Err(_) => set_result("[]".into()),
    }
}

// ---- Shared implementation (used by both PyO3 and C ABI paths) ----

fn exec_analyze_strategy_impl(workload_type: &str, devices_json: &str) -> Result<String, String> {
    let wl = parse_workload_type(workload_type)
        .map_err(|e| e.to_string())?;
    let devices = parse_devices(devices_json)
        .map_err(|e| e.to_string())?;

    let mut decomposer = executor::TaskDecomposer::new();
    for d in &devices {
        decomposer.register_device(d.clone());
    }

    let task = executor::Task {
        id: "analysis".into(),
        description: String::new(),
        workload_type: wl,
        sub_tasks: vec![],
        strategy: executor::ExecutionStrategy::Local,
        priority: 5,
        status: executor::TaskStatus::Pending,
    };

    let strategy = decomposer.analyze(&task);
    let (strategy_name, target_node) = match &strategy {
        executor::ExecutionStrategy::Local => ("local", None),
        executor::ExecutionStrategy::Parallelized => ("parallelized", None),
        executor::ExecutionStrategy::Fused => ("fused", None),
        executor::ExecutionStrategy::RelayTo(id) => ("relay_to", Some(id.clone())),
    };

    let result = serde_json::json!({
        "strategy": strategy_name,
        "target_node": target_node,
    });

    serde_json::to_string(&result).map_err(|e| e.to_string())
}

fn exec_decompose_impl(
    task_id: &str, description: &str,
    workload_type: &str, devices_json: &str,
) -> Result<String, String> {
    let wl = parse_workload_type(workload_type)
        .map_err(|e| e.to_string())?;
    let devices = parse_devices(devices_json)
        .map_err(|e| e.to_string())?;

    let mut decomposer = executor::TaskDecomposer::new();
    for d in &devices {
        decomposer.register_device(d.clone());
    }

    let mut task = executor::Task {
        id: task_id.into(),
        description: description.into(),
        workload_type: wl,
        sub_tasks: vec![],
        strategy: executor::ExecutionStrategy::Local,
        priority: 5,
        status: executor::TaskStatus::Pending,
    };

    let sub_tasks = decomposer.decompose(&mut task);

    let result: Vec<serde_json::Value> = sub_tasks
        .iter()
        .map(|st| {
            serde_json::json!({
                "id": st.id,
                "description": st.description,
                "assigned_node": st.assigned_node,
                "workload_type": serde_json::to_string(&st.workload_type)
                    .unwrap_or_default()
                    .trim_matches('"'),
                "estimated_cost": st.estimated_cost,
            })
        })
        .collect();

    serde_json::to_string(&result).map_err(|e| e.to_string())
}

fn exec_find_capable_devices_impl(
    workload_type: &str, devices_json: &str,
) -> Result<String, String> {
    let wl = parse_workload_type(workload_type)
        .map_err(|e| e.to_string())?;
    let devices = parse_devices(devices_json)
        .map_err(|e| e.to_string())?;

    let mut decomposer = executor::TaskDecomposer::new();
    for d in &devices {
        decomposer.register_device(d.clone());
    }

    let mut task = executor::Task {
        id: "find".into(),
        description: String::new(),
        workload_type: wl,
        sub_tasks: vec![],
        strategy: executor::ExecutionStrategy::Local,
        priority: 5,
        status: executor::TaskStatus::Pending,
    };

    let sub_tasks = decomposer.decompose(&mut task);

    let node_ids: Vec<String> = sub_tasks
        .iter()
        .filter_map(|st| st.assigned_node.clone())
        .collect();

    serde_json::to_string(&node_ids).map_err(|e| e.to_string())
}

// ---------------------------------------------------------------------------
// Module registration
// ---------------------------------------------------------------------------

#[pymodule]
#[pyo3(name = "_nexus_core")]
fn nexus_core_module(_py: Python<'_>, m: &PyModule) -> PyResult<()> {
    m.add_function(wrap_pyfunction!(encrypt_message, m)?)?;
    m.add_function(wrap_pyfunction!(decrypt_message, m)?)?;
    m.add_function(wrap_pyfunction!(derive_key, m)?)?;
    m.add_function(wrap_pyfunction!(scan_capabilities, m)?)?;
    m.add_function(wrap_pyfunction!(exec_analyze_strategy, m)?)?;
    m.add_function(wrap_pyfunction!(exec_decompose, m)?)?;
    m.add_function(wrap_pyfunction!(exec_find_capable_devices, m)?)?;
    m.add("__version__", env!("CARGO_PKG_VERSION"))?;
    m.add("PROTOCOL_VERSION", crate::PROTOCOL_VERSION)?;
    Ok(())
}
