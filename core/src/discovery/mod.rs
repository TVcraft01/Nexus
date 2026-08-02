//! Device discovery and capability scanning.
//!
//! Uses mDNS to discover Nexus nodes on the local network and
//! scans each device to determine its capabilities (CPU, RAM, GPU,
//! available AI models, connected peripherals).

use serde::{Deserialize, Serialize};
use std::collections::HashMap;

use crate::{CapabilityScore, NodeId};

// ---------------------------------------------------------------------------
// Device capability profile
// ---------------------------------------------------------------------------

/// Represents the hardware and software capabilities of a Nexus node.
/// This determines which modules and AI models can be deployed to the device.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DeviceCapabilities {
    /// Unique node identifier
    pub node_id: NodeId,

    /// Human-readable name
    pub hostname: String,

    /// Device class: phone, desktop, tv, iot, car, etc.
    pub device_class: DeviceClass,

    /// Operating system
    pub os: OsInfo,

    /// CPU information
    pub cpu: CpuInfo,

    /// RAM in megabytes
    pub ram_mb: u64,

    /// Available storage in megabytes
    pub storage_mb: u64,

    /// GPU information (if available)
    pub gpu: Option<GpuInfo>,

    /// Network interfaces
    pub network: Vec<NetworkInterface>,

    /// Connected peripherals (cameras, microphones, speakers, etc.)
    pub peripherals: Vec<Peripheral>,

    /// Available AI/ML capabilities
    pub ai_capabilities: AiCapabilities,

    /// Overall capability score (0.0 - 1.0)
    /// Used for task scheduling: higher score = more capable
    pub capability_score: CapabilityScore,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum DeviceClass {
    Phone,
    Desktop,
    Laptop,
    Tablet,
    Tv,
    IotLight,
    IotThermostat,
    IotCamera,
    IotSpeaker,
    IotVacuum,
    Car,
    Server,
    Watch,
    Unknown,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OsInfo {
    pub name: String,
    pub version: String,
    pub arch: String, // x86_64, aarch64, armv7, etc.
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CpuInfo {
    pub model: String,
    pub cores: u32,
    pub frequency_mhz: Option<u64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GpuInfo {
    pub model: String,
    pub vram_mb: Option<u64>,
    /// Whether the GPU can be used for ML inference (CUDA, Metal, Vulkan)
    pub ml_capable: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NetworkInterface {
    pub name: String,
    pub ip_address: String,
    pub mac_address: Option<String>,
    /// Interfaces that can reach external networks (e.g., for relay)
    pub has_internet: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Peripheral {
    pub peripheral_type: PeripheralType,
    pub name: String,
    pub available: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum PeripheralType {
    Camera,
    Microphone,
    Speaker,
    Display,
    UsbPort,
    BluetoothAdapter,
    NfcReader,
    Gps,
    Accelerometer,
    FingerprintSensor,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AiCapabilities {
    /// Whether a local LLM is available
    pub local_llm_available: bool,

    /// Available LLM backends
    pub llm_backends: Vec<String>,

    /// Available models (e.g., "llama3.2", "tinyllama")
    pub available_models: Vec<String>,

    /// Whether this device can run voice recognition locally
    pub voice_recognition: bool,

    /// Whether this device can run computer vision locally
    pub computer_vision: bool,

    /// ML framework support
    pub ml_frameworks: Vec<String>,
}

// ---------------------------------------------------------------------------
// Discovery service
// ---------------------------------------------------------------------------

/// Represents a discovered or registered device in the Nexus ecosystem.
#[derive(Debug, Clone)]
pub struct DiscoveredDevice {
    pub capabilities: DeviceCapabilities,
    pub address: String,
    pub port: u16,
    pub last_seen: u64,
    pub paired: bool,
}

/// Manages device discovery across the local network.
pub struct DiscoveryService {
    devices: HashMap<NodeId, DiscoveredDevice>,
    #[cfg(feature = "mdns")]
    mdns_browser: Option<mdns_sd::ServiceDaemon>,
}

impl DiscoveryService {
    pub fn new() -> Self {
        Self {
            devices: HashMap::new(),
            #[cfg(feature = "mdns")]
            mdns_browser: None,
        }
    }

    /// Register a device (self-registration or discovery).
    pub fn register_device(&mut self, device: DiscoveredDevice) {
        self.devices.insert(device.capabilities.node_id.clone(), device);
    }

    /// Remove a device.
    pub fn remove_device(&mut self, node_id: &NodeId) {
        self.devices.remove(node_id);
    }

    /// List all discovered devices.
    pub fn list_devices(&self) -> Vec<&DiscoveredDevice> {
        self.devices.values().collect()
    }

    /// Find a device by node ID.
    pub fn get_device(&self, node_id: &NodeId) -> Option<&DiscoveredDevice> {
        self.devices.get(node_id)
    }

    /// Find devices by class (e.g., all cameras, all phones).
    pub fn find_by_class(&self, class: DeviceClass) -> Vec<&DiscoveredDevice> {
        self.devices
            .values()
            .filter(|d| d.capabilities.device_class == class)
            .collect()
    }

    /// Find devices with a specific peripheral type.
    pub fn find_by_peripheral(&self, ptype: PeripheralType) -> Vec<&DiscoveredDevice> {
        self.devices
            .values()
            .filter(|d| d.capabilities.peripherals.iter().any(|p| p.peripheral_type == ptype && p.available))
            .collect()
    }

    /// Get the most capable device (highest capability score).
    pub fn most_capable(&self) -> Option<&DiscoveredDevice> {
        self.devices
            .values()
            .max_by(|a, b| a.capabilities.capability_score.partial_cmp(&b.capabilities.capability_score).unwrap())
    }
}

impl Default for DiscoveryService {
    fn default() -> Self {
        Self::new()
    }
}

// ---------------------------------------------------------------------------
// Capability scanning (platform-specific)
// ---------------------------------------------------------------------------

/// Scan the current device to build a DeviceCapabilities profile.
pub fn scan_local_capabilities(node_id: NodeId, hostname: String) -> DeviceCapabilities {
    let (cpu, ram_mb) = scan_cpu();
    let storage_mb = scan_storage();
    let os = scan_os();
    let network = scan_network();
    let peripherals = scan_peripherals();
    let ai = scan_ai_capabilities();

    let device_class = classify_device(&os);

    let score = compute_capability_score(&cpu, ram_mb, &ai);

    DeviceCapabilities {
        node_id,
        hostname,
        device_class,
        os,
        cpu,
        ram_mb,
        storage_mb,
        gpu: scan_gpu(),
        network,
        peripherals,
        ai_capabilities: ai,
        capability_score: score,
    }
}

fn scan_cpu() -> (CpuInfo, u64) {
    let model = if cfg!(target_arch = "x86_64") {
        "x86_64 CPU".into()
    } else if cfg!(target_arch = "aarch64") {
        "ARM64 CPU".into()
    } else {
        "Unknown CPU".into()
    };

    let cores = std::thread::available_parallelism()
        .map(|n| n.get() as u32)
        .unwrap_or(1);

    let ram = estimate_ram_mb();

    (CpuInfo { model, cores, frequency_mhz: None }, ram)
}

fn estimate_ram_mb() -> u64 {
    // Platform-specific RAM detection
    #[cfg(target_os = "linux")]
    {
        if let Ok(proc_mem) = std::fs::read_to_string("/proc/meminfo") {
            for line in proc_mem.lines() {
                if line.starts_with("MemTotal:") {
                    let kb: u64 = line
                        .split_whitespace()
                        .nth(1)
                        .and_then(|s| s.parse().ok())
                        .unwrap_or(0);
                    return kb / 1024;
                }
            }
        }
    }
    1024 // Default: assume at least 1 GB
}

fn scan_storage() -> u64 {
    // Rough estimate of available storage
    #[cfg(target_os = "linux")]
    {
        if let Ok(df) = std::process::Command::new("df")
            .arg("-m")
            .arg("/")
            .output()
        {
            let output = String::from_utf8_lossy(&df.stdout);
            if let Some(line) = output.lines().nth(1) {
                if let Some(avail) = line.split_whitespace().nth(3) {
                    return avail.parse().unwrap_or(1024);
                }
            }
        }
    }
    1024
}

fn scan_os() -> OsInfo {
    OsInfo {
        name: std::env::consts::OS.into(),
        version: String::new(), // filled by Python layer
        arch: std::env::consts::ARCH.into(),
    }
}

fn scan_network() -> Vec<NetworkInterface> {
    // Stub - real implementation uses platform-specific APIs
    vec![NetworkInterface {
        name: "default".into(),
        ip_address: "127.0.0.1".into(),
        mac_address: None,
        has_internet: false,
    }]
}

fn scan_peripherals() -> Vec<Peripheral> {
    // Stub - platform-specific camera/mic/etc detection
    Vec::new()
}

fn scan_gpu() -> Option<GpuInfo> {
    None // Stub
}

fn scan_ai_capabilities() -> AiCapabilities {
    AiCapabilities {
        local_llm_available: false,
        llm_backends: Vec::new(),
        available_models: Vec::new(),
        voice_recognition: false,
        computer_vision: false,
        ml_frameworks: Vec::new(),
    }
}

fn classify_device(_os: &OsInfo) -> DeviceClass {
    if cfg!(target_os = "android") {
        // More precise classification happens in the Android layer
        DeviceClass::Phone
    } else if cfg!(target_os = "linux") {
        DeviceClass::Desktop
    } else {
        DeviceClass::Unknown
    }
}

fn compute_capability_score(cpu: &CpuInfo, ram_mb: u64, ai: &AiCapabilities) -> f32 {
    let mut score = 0.0;

    // RAM factor: 0-0.4
    score += (ram_mb as f32 / 32768.0).min(1.0) * 0.4;

    // CPU factor: 0-0.3
    score += (cpu.cores as f32 / 16.0).min(1.0) * 0.3;

    // AI factor: 0-0.3
    if ai.local_llm_available {
        score += 0.15;
    }
    if ai.computer_vision {
        score += 0.1;
    }
    if !ai.available_models.is_empty() {
        score += 0.05;
    }

    score.min(1.0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_capability_scan() {
        let caps = scan_local_capabilities("test-node".into(), "localhost".into());
        assert!(!caps.node_id.is_empty());
        assert!(caps.cpu.cores > 0);
        assert!(caps.ram_mb > 0);
        assert!(caps.capability_score >= 0.0);
        assert!(caps.capability_score <= 1.0);
    }

    #[test]
    fn test_discovery_service() {
        let mut svc = DiscoveryService::new();
        let caps = scan_local_capabilities("n1".into(), "Phone".into());
        svc.register_device(DiscoveredDevice {
            capabilities: caps,
            address: "192.168.1.5".into(),
            port: 9090,
            last_seen: 0,
            paired: false,
        });
        assert_eq!(svc.list_devices().len(), 1);
        assert!(svc.most_capable().is_some());
    }
}
