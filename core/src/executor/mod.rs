//! Task decomposition and distributed execution engine.
//!
//! Handles two strategies for complex task execution across the device mesh:
//!
//! **Strategy A - Parallelization**: Break tasks into sub-tasks and distribute
//!   them to the most efficient devices (e.g., rendering → TV's GPU, logic → PC).
//!
//! **Strategy B - Fusion**: Pool the computational power of all connected devices
//!   to brute-force a single task when that's faster than decomposition.

use std::collections::HashMap;

use serde::{Deserialize, Serialize};
use tokio::sync::broadcast;

use crate::discovery::{DeviceCapabilities, DiscoveredDevice, DeviceClass, PeripheralType};
use crate::NodeId;

// ---------------------------------------------------------------------------
// Task model
// ---------------------------------------------------------------------------

/// A task that can be distributed across the Nexus mesh.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Task {
    /// Unique task identifier
    pub id: String,

    /// Human-readable description
    pub description: String,

    /// The type of workload
    pub workload_type: WorkloadType,

    /// Sub-tasks (populated after decomposition)
    pub sub_tasks: Vec<SubTask>,

    /// The computed execution strategy
    pub strategy: ExecutionStrategy,

    /// Priority (0 = lowest, 10 = highest)
    pub priority: u8,

    /// Task status
    pub status: TaskStatus,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum WorkloadType {
    /// CPU-bound computation (math, crypto, encoding)
    Compute,
    /// GPU-bound (rendering, ML inference)
    GpuCompute,
    /// I/O bound (network, storage)
    Io,
    /// Mixed workload
    Mixed,
    /// Simple command relay (no computation needed)
    Command,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum ExecutionStrategy {
    /// Run on the local node only
    Local,
    /// Decomposed and distributed via Strategy A
    Parallelized,
    /// Pooled compute via Strategy B (Fusion)
    Fused,
    /// Relay to a specific node
    RelayTo(NodeId),
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum TaskStatus {
    Pending,
    Decomposing,
    Scheduled,
    Running,
    Completed,
    Failed(String),
}

/// A sub-task produced by decomposition.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SubTask {
    pub id: String,
    pub description: String,
    pub workload_type: WorkloadType,
    /// Which node is assigned to execute this sub-task
    pub assigned_node: Option<NodeId>,
    /// Estimated compute units needed
    pub estimated_cost: f64,
    pub status: TaskStatus,
}

// ---------------------------------------------------------------------------
// Task Decomposer
// ---------------------------------------------------------------------------

/// Decomposes complex tasks into sub-tasks based on available device capabilities.
pub struct TaskDecomposer {
    /// Map of node ID → device capabilities
    device_registry: HashMap<NodeId, DiscoveredDevice>,
}

impl TaskDecomposer {
    pub fn new() -> Self {
        Self {
            device_registry: HashMap::new(),
        }
    }

    /// Register a device's capabilities for scheduling.
    pub fn register_device(&mut self, device: DiscoveredDevice) {
        self.device_registry
            .insert(device.capabilities.node_id.clone(), device);
    }

    /// Remove a device from scheduling.
    pub fn remove_device(&mut self, node_id: &NodeId) {
        self.device_registry.remove(node_id);
    }

    /// Analyze a task and determine the optimal execution strategy.
    pub fn analyze(&self, task: &Task) -> ExecutionStrategy {
        match task.workload_type {
            WorkloadType::Command | WorkloadType::Io => {
                // Simple commands and I/O run on the most relevant device
                ExecutionStrategy::Local
            }
            WorkloadType::Compute | WorkloadType::Mixed => {
                let capable_devices = self.find_capable_devices_for(&task.workload_type);
                if capable_devices.len() > 1 {
                    ExecutionStrategy::Parallelized
                } else {
                    ExecutionStrategy::Local
                }
            }
            WorkloadType::GpuCompute => {
                let gpu_devices = self.find_gpu_devices();
                if let Some(best_gpu) = gpu_devices.first() {
                    ExecutionStrategy::RelayTo(best_gpu.capabilities.node_id.clone())
                } else {
                    ExecutionStrategy::Local
                }
            }
        }
    }

    /// Decompose a task into sub-tasks (Strategy A).
    pub fn decompose(&self, task: &mut Task) -> Vec<SubTask> {
        let capable_devices = self.find_capable_devices_for(&task.workload_type);

        if capable_devices.is_empty() {
            // Run everything locally
            return vec![SubTask {
                id: format!("{}-0", task.id),
                description: task.description.clone(),
                workload_type: task.workload_type.clone(),
                assigned_node: None, // local node
                estimated_cost: 1.0,
                status: TaskStatus::Pending,
            }];
        }

        // Split task evenly among capable devices
        let mut sub_tasks = Vec::new();
        let chunk_count = capable_devices.len();

        for (i, device) in capable_devices.iter().enumerate() {
            sub_tasks.push(SubTask {
                id: format!("{}-{}", task.id, i),
                description: format!("{} (part {}/{})", task.description, i + 1, chunk_count),
                workload_type: task.workload_type.clone(),
                assigned_node: Some(device.capabilities.node_id.clone()),
                estimated_cost: 1.0 / chunk_count as f64,
                status: TaskStatus::Pending,
            });
        }

        sub_tasks
    }

    /// Determine if fusion (Strategy B) should be used.
    /// Fusion is beneficial when:
    /// - The task is highly parallelizable
    /// - Multiple devices have similar capabilities
    /// - Network latency is low
    pub fn should_fuse(&self, task: &Task, available_devices: &[DiscoveredDevice]) -> bool {
        match task.workload_type {
            WorkloadType::Compute | WorkloadType::GpuCompute => {
                // Only fuse if we have 3+ capable devices
                available_devices.len() >= 3
            }
            _ => false,
        }
    }

    /// Find devices capable of handling a given workload type.
    fn find_capable_devices_for(&self, workload: &WorkloadType) -> Vec<&DiscoveredDevice> {
        self.device_registry
            .values()
            .filter(|d| self.device_can_handle(d, workload))
            .collect()
    }

    /// Check if a device has sufficient capabilities for a workload.
    fn device_can_handle(&self, device: &DiscoveredDevice, workload: &WorkloadType) -> bool {
        match workload {
            WorkloadType::Compute => {
                device.capabilities.cpu.cores >= 2 && device.capabilities.ram_mb >= 256
            }
            WorkloadType::GpuCompute => {
                device.capabilities.gpu.as_ref().map(|g| g.ml_capable).unwrap_or(false)
            }
            WorkloadType::Io => true,
            WorkloadType::Mixed => {
                device.capabilities.cpu.cores >= 4 && device.capabilities.ram_mb >= 1024
            }
            WorkloadType::Command => true,
        }
    }

    /// Find devices with ML-capable GPUs.
    fn find_gpu_devices(&self) -> Vec<&DiscoveredDevice> {
        self.device_registry
            .values()
            .filter(|d| d.capabilities.gpu.as_ref().map(|g| g.ml_capable).unwrap_or(false))
            .collect()
    }

    /// Find devices with cameras (for vision tasks).
    pub fn find_camera_devices(&self) -> Vec<&DiscoveredDevice> {
        self.device_registry
            .values()
            .filter(|d| {
                d.capabilities
                    .peripherals
                    .iter()
                    .any(|p| p.peripheral_type == PeripheralType::Camera && p.available)
            })
            .collect()
    }
}

impl Default for TaskDecomposer {
    fn default() -> Self {
        Self::new()
    }
}

// ---------------------------------------------------------------------------
// Task executor (async)
// ---------------------------------------------------------------------------

/// Manages task lifecycle: decomposition, scheduling, execution, completion.
pub struct TaskExecutor {
    decomposer: TaskDecomposer,
    active_tasks: HashMap<String, Task>,
    result_tx: broadcast::Sender<TaskResult>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TaskResult {
    pub task_id: String,
    pub success: bool,
    pub output: String,
    pub executed_by: NodeId,
}

impl TaskExecutor {
    pub fn new() -> Self {
        let (tx, _) = broadcast::channel(64);
        Self {
            decomposer: TaskDecomposer::new(),
            active_tasks: HashMap::new(),
            result_tx: tx,
        }
    }

    /// Submit a task for execution.
    pub fn submit(&mut self, mut task: Task) {
        task.status = TaskStatus::Decomposing;

        // Determine strategy
        let strategy = self.decomposer.analyze(&task);
        task.strategy = strategy;

        match task.strategy {
            ExecutionStrategy::Local => {
                task.sub_tasks = vec![SubTask {
                    id: format!("{}-0", task.id),
                    description: task.description.clone(),
                    workload_type: task.workload_type.clone(),
                    assigned_node: None,
                    estimated_cost: 1.0,
                    status: TaskStatus::Pending,
                }];
            }
            ExecutionStrategy::Parallelized => {
                task.sub_tasks = self.decomposer.decompose(&mut task);
            }
            ExecutionStrategy::Fused => {
                // Fusion pools all device compute - sub-tasks handled by fusion engine
                task.sub_tasks = self.decomposer.decompose(&mut task);
            }
            ExecutionStrategy::RelayTo(_) => {
                task.sub_tasks = vec![SubTask {
                    id: format!("{}-0", task.id),
                    description: task.description.clone(),
                    workload_type: task.workload_type.clone(),
                    assigned_node: Some(task.strategy.clone().into()),
                    estimated_cost: 1.0,
                    status: TaskStatus::Pending,
                }];
            }
        }

        task.status = TaskStatus::Scheduled;
        self.active_tasks.insert(task.id.clone(), task);
    }

    /// Get a subscriber for task results.
    pub fn subscribe_results(&self) -> broadcast::Receiver<TaskResult> {
        self.result_tx.subscribe()
    }

    /// List all active tasks.
    pub fn list_tasks(&self) -> Vec<&Task> {
        self.active_tasks.values().collect()
    }
}

impl Default for TaskExecutor {
    fn default() -> Self {
        Self::new()
    }
}

impl From<ExecutionStrategy> for Option<NodeId> {
    fn from(s: ExecutionStrategy) -> Self {
        match s {
            ExecutionStrategy::RelayTo(id) => Some(id),
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::discovery::{scan_local_capabilities, DiscoveredDevice};

    fn make_task(name: &str, wl: WorkloadType) -> Task {
        Task {
            id: name.into(),
            description: "Test task".into(),
            workload_type: wl,
            sub_tasks: vec![],
            strategy: ExecutionStrategy::Local,
            priority: 5,
            status: TaskStatus::Pending,
        }
    }

    #[test]
    fn test_local_task() {
        let mut executor = TaskExecutor::new();
        let task = make_task("test-1", WorkloadType::Command);
        executor.submit(task);
        assert_eq!(executor.list_tasks().len(), 1);
    }

    #[test]
    fn test_parallelization_strategy() {
        let mut decomposer = TaskDecomposer::new();

        // Register two capable devices
        for i in 1..=2 {
            let caps = scan_local_capabilities(format!("node-{}", i), format!("Device {}", i));
            decomposer.register_device(DiscoveredDevice {
                capabilities: caps,
                address: "192.168.1.1".into(),
                port: 9090,
                last_seen: 0,
                paired: true,
            });
        }

        let task = make_task("compute-1", WorkloadType::Compute);
        let strategy = decomposer.analyze(&task);
        assert_eq!(strategy, ExecutionStrategy::Parallelized);
    }
}
