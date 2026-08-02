# Distributed Task Executor
#
# Implements Nexus' task decomposition and distributed execution engine.
# Handles both Strategy A (Parallelization) and Strategy B (Fusion/compute pooling).
#
# Key features:
# - Decompose complex tasks into sub-tasks based on device capabilities
# - Distribute sub-tasks to capable devices via MQTT/TCP
# - Collect and aggregate results
# - Handle node failures gracefully (timeout + retry)

from __future__ import annotations

import json
import logging
import threading
import time
import uuid
from dataclasses import dataclass, field
from enum import Enum
from typing import Any, Callable, Dict, List, Optional

logger = logging.getLogger("nexus.orchestrator.task_executor")


# ---------------------------------------------------------------------------
# Task models (mirrors Rust executor)
# ---------------------------------------------------------------------------

class WorkloadType(Enum):
    COMPUTE = "compute"
    GPU_COMPUTE = "gpu_compute"
    IO = "io"
    MIXED = "mixed"
    COMMAND = "command"
    VISION = "vision"    # Computer vision tasks
    LLM = "llm"          # LLM inference tasks


class ExecutionStrategy(Enum):
    LOCAL = "local"
    PARALLELIZED = "parallelized"
    FUSED = "fused"
    RELAY_TO = "relay_to"


class TaskStatus(Enum):
    PENDING = "pending"
    DECOMPOSING = "decomposing"
    SCHEDULED = "scheduled"
    RUNNING = "running"
    AWAITING_RESULTS = "awaiting_results"
    COMPLETED = "completed"
    FAILED = "failed"
    TIMED_OUT = "timed_out"


@dataclass
class SubTask:
    id: str
    description: str
    command: str                          # The actual command to execute
    workload_type: WorkloadType
    assigned_node: Optional[str] = None   # Node ID for execution
    estimated_cost: float = 1.0
    status: TaskStatus = TaskStatus.PENDING
    result: Optional[str] = None
    started_at: Optional[float] = None
    completed_at: Optional[float] = None


@dataclass
class NexusTask:
    id: str
    description: str
    workload_type: WorkloadType
    strategy: ExecutionStrategy = ExecutionStrategy.LOCAL
    priority: int = 5                        # 0-10
    sub_tasks: List[SubTask] = field(default_factory=list)
    status: TaskStatus = TaskStatus.PENDING
    created_at: float = field(default_factory=time.time)
    completed_at: Optional[float] = None
    result_summary: str = ""

    @property
    def is_complete(self) -> bool:
        return self.status in (TaskStatus.COMPLETED, TaskStatus.FAILED, TaskStatus.TIMED_OUT)

    @property
    def progress(self) -> float:
        """Completion ratio (0.0 - 1.0)."""
        if not self.sub_tasks:
            return 0.0
        done = sum(1 for st in self.sub_tasks
                  if st.status in (TaskStatus.COMPLETED, TaskStatus.FAILED))
        return done / len(self.sub_tasks)


# ---------------------------------------------------------------------------
# Task Decomposer
# ---------------------------------------------------------------------------

class TaskDecomposer:
    """Analyzes tasks and decomposes them based on available device capabilities.

    Tries the Rust executor engine first (when available), falls back to pure
    Python for strategy analysis and task decomposition.
    """

    def __init__(self):
        self.device_capabilities: Dict[str, dict] = {}
        self._rust_exec = self._init_rust_executor()
        self._use_rust = self._rust_exec is not None

    @staticmethod
    def _init_rust_executor():
        """Try to initialize the Rust executor engine."""
        try:
            from nexus_server._nexus_core import RustTaskExecutor
            exec = RustTaskExecutor()
            if exec.available:
                logger.info("Rust executor engine loaded — distributed task execution active")
                return exec
            else:
                logger.debug("Rust core not available for executor — using Python fallback")
                return None
        except ImportError:
            logger.debug("Rust executor not available — using Python fallback")
            return None

    def _devices_as_list(self) -> list:
        """Convert device capabilities dict to a JSON-compatible list for Rust FFI."""
        return list(self.device_capabilities.values())

    def register_device(self, node_id: str, capabilities: dict) -> None:
        self.device_capabilities[node_id] = capabilities

    def remove_device(self, node_id: str) -> None:
        self.device_capabilities.pop(node_id, None)

    def analyze_strategy(self, workload_type: WorkloadType) -> ExecutionStrategy:
        """Determine the best execution strategy based on available devices."""
        wl_str = workload_type.value

        # Try Rust engine first
        if self._use_rust and self._rust_exec:
            try:
                result = self._rust_exec.analyze_strategy(
                    wl_str, self._devices_as_list(),
                )
                strategy_name = result.get("strategy", "local")
                target = result.get("target_node")
                logger.debug(f"Rust strategy: {strategy_name} (target: {target})")
                return _str_to_strategy(strategy_name)
            except Exception as e:
                logger.debug(f"Rust analyze_strategy failed, falling back: {e}")

        # Python fallback
        capable = self.find_capable_devices(workload_type)

        if not capable:
            return ExecutionStrategy.LOCAL

        if len(capable) <= 1:
            if workload_type == WorkloadType.GPU_COMPUTE:
                for nid in capable:
                    caps = self.device_capabilities.get(nid, {})
                    if caps.get("gpu", {}).get("ml_capable", False):
                        return ExecutionStrategy.RELAY_TO
            return ExecutionStrategy.LOCAL

        if workload_type in (WorkloadType.COMPUTE, WorkloadType.MIXED):
            if len(capable) >= 3:
                return ExecutionStrategy.FUSED
            return ExecutionStrategy.PARALLELIZED

        if workload_type == WorkloadType.GPU_COMPUTE:
            return ExecutionStrategy.RELAY_TO

        return ExecutionStrategy.LOCAL

    def find_capable_devices(self, workload_type: WorkloadType) -> List[str]:
        """Find device IDs capable of handling the workload.

        Tries the Rust engine first for capability matching, falls back to
        Python heuristic.
        """
        wl_str = workload_type.value

        # Try Rust engine first
        if self._use_rust and self._rust_exec:
            try:
                result = self._rust_exec.find_capable_devices(
                    wl_str, self._devices_as_list(),
                )
                if result:
                    logger.debug(f"Rust found {len(result)} capable devices for {wl_str}")
                    return result
            except Exception as e:
                logger.debug(f"Rust find_capable_devices failed, falling back: {e}")

        # Python fallback
        capable = []

        for node_id, caps in self.device_capabilities.items():
            if self._can_handle(node_id, caps, workload_type):
                capable.append(node_id)

        # Sort by capability score (descending) so best devices are first
        capable.sort(
            key=lambda nid: self.device_capabilities.get(nid, {}).get("capability_score", 0),
            reverse=True,
        )
        return capable

    def _can_handle(self, node_id: str, caps: dict, workload: WorkloadType) -> bool:
        """Check if a device can handle a specific workload."""
        cpu = caps.get("cpu") or {}
        ram = caps.get("ram_mb", 0)
        gpu = caps.get("gpu") or {}  # Handle None/null GPU
        ai = caps.get("ai_capabilities") or {}

        if workload == WorkloadType.COMMAND:
            return True

        if workload == WorkloadType.COMPUTE:
            return cpu.get("cores", 0) >= 2 and ram >= 256

        if workload == WorkloadType.GPU_COMPUTE:
            return gpu.get("ml_capable", False)

        if workload == WorkloadType.VISION:
            return any(
                p.get("peripheral_type") == "camera" and p.get("available")
                for p in caps.get("peripherals", [])
            )

        if workload == WorkloadType.LLM:
            return ai.get("local_llm_available", False)

        if workload == WorkloadType.MIXED:
            return cpu.get("cores", 0) >= 4 and ram >= 1024

        return True

    def decompose(self, task: NexusTask) -> List[SubTask]:
        """Break a task into sub-tasks for parallel execution."""
        wl_str = task.workload_type.value

        # Try Rust engine first
        if self._use_rust and self._rust_exec:
            try:
                rust_subtasks = self._rust_exec.decompose(
                    task.id, task.description,
                    wl_str, self._devices_as_list(),
                )
                if rust_subtasks:
                    logger.debug(
                        f"Rust decomposed task {task.id} into "
                        f"{len(rust_subtasks)} sub-tasks"
                    )
                    return [
                        SubTask(
                            id=st.get("id", f"{task.id}-0"),
                            description=st.get("description", task.description),
                            command=task.description,
                            workload_type=task.workload_type,
                            assigned_node=st.get("assigned_node"),
                            estimated_cost=st.get("estimated_cost", 1.0),
                        )
                        for st in rust_subtasks
                    ]
            except Exception as e:
                logger.debug(f"Rust decompose failed, falling back: {e}")

        # Python fallback
        capable_nodes = self.find_capable_devices(task.workload_type)

        if not capable_nodes:
            # Execute locally
            return [SubTask(
                id=f"{task.id}-0",
                description=task.description,
                command=task.description,
                workload_type=task.workload_type,
                assigned_node=None,  # local
            )]

        sub_tasks = []
        for i, node_id in enumerate(capable_nodes):
            sub_tasks.append(SubTask(
                id=f"{task.id}-{i}",
                description=f"{task.description} (node: {node_id})",
                command=task.description,
                workload_type=task.workload_type,
                assigned_node=node_id,
                estimated_cost=1.0 / len(capable_nodes),
            ))

        return sub_tasks

    def get_best_gpu_node(self) -> Optional[str]:
        """Find the node with the best GPU for ML tasks."""
        best_node = None
        best_vram = 0

        for node_id, caps in self.device_capabilities.items():
            gpu = caps.get("gpu", {})
            vram = gpu.get("vram_mb", 0)
            if gpu.get("ml_capable", False) and vram > best_vram:
                best_vram = vram
                best_node = node_id

        return best_node

    def get_best_vision_node(self) -> Optional[str]:
        """Find the node with the best camera setup."""
        for node_id, caps in self.device_capabilities.items():
            cameras = [
                p for p in caps.get("peripherals", [])
                if p.get("peripheral_type") == "camera" and p.get("available")
            ]
            if cameras:
                return node_id
        return None


# ---------------------------------------------------------------------------
# Task Executor
# ---------------------------------------------------------------------------

class DistributedTaskExecutor:
    """Manages the lifecycle of distributed tasks across the Nexus mesh."""

    def __init__(
        self,
        on_dispatch: Optional[Callable[[str, SubTask], bool]] = None,
    ):
        self.decomposer = TaskDecomposer()
        self.on_dispatch = on_dispatch

        self._tasks: Dict[str, NexusTask] = {}
        self._lock = threading.Lock()
        self._result_callbacks: Dict[str, Callable] = {}

        # Timeouts
        self.default_timeout_s = 60
        self._timeout_thread: Optional[threading.Thread] = None
        self._running = False

    # ------------------------------------------------------------------
    # Lifecycle
    # ------------------------------------------------------------------

    def start(self) -> None:
        self._running = True
        self._timeout_thread = threading.Thread(
            target=self._timeout_checker, daemon=True,
        )
        self._timeout_thread.start()

    def stop(self) -> None:
        self._running = False

    # ------------------------------------------------------------------
    # Task submission
    # ------------------------------------------------------------------

    def submit(
        self,
        description: str,
        workload_type: WorkloadType,
        priority: int = 5,
        on_complete: Optional[Callable] = None,
    ) -> NexusTask:
        """Submit a new task for distributed execution."""
        task = NexusTask(
            id=f"task-{uuid.uuid4().hex[:8]}",
            description=description,
            workload_type=workload_type,
            priority=priority,
        )

        # Analyze best strategy
        task.strategy = self.decomposer.analyze_strategy(workload_type)

        # Decompose if parallel or fused
        if task.strategy in (ExecutionStrategy.PARALLELIZED, ExecutionStrategy.FUSED):
            task.sub_tasks = self.decomposer.decompose(task)
        else:
            # Single local sub-task
            task.sub_tasks = [SubTask(
                id=f"{task.id}-0",
                description=description,
                command=description,
                workload_type=workload_type,
                assigned_node=None,
            )]

        task.status = TaskStatus.SCHEDULED

        with self._lock:
            self._tasks[task.id] = task
            if on_complete:
                self._result_callbacks[task.id] = on_complete

        logger.info(f"Task {task.id} scheduled: '{description}' "
                   f"strategy={task.strategy.value}, "
                   f"sub_tasks={len(task.sub_tasks)}")

        # Start dispatching
        self._dispatch_task(task)

        return task

    def _dispatch_task(self, task: NexusTask) -> None:
        """Dispatch sub-tasks to assigned nodes."""
        task.status = TaskStatus.RUNNING

        for subtask in task.sub_tasks:
            subtask.status = TaskStatus.RUNNING
            subtask.started_at = time.time()

            if subtask.assigned_node is None:
                # Execute locally via injected executor
                self._execute_local_subtask(task.id, subtask)
            elif self.on_dispatch:
                # Dispatch to remote node
                dispatched = self.on_dispatch(subtask.assigned_node, subtask)
                if not dispatched:
                    # Fallback: execute locally
                    self._execute_local_subtask(task.id, subtask)

        # If all local, mark complete
        self._check_completion(task.id)

    _local_executor: Optional[Callable] = None

    def set_local_executor(self, executor_func: Callable[[str], tuple]) -> None:
        """Set a function to execute commands locally.

        The function takes a command string and returns (success: bool, output: str).
        """
        self._local_executor = executor_func

    def _execute_local_subtask(self, task_id: str, subtask: SubTask) -> None:
        """Execute a subtask locally using the injected executor."""
        if self._local_executor:
            try:
                success, output = self._local_executor(subtask.command)
                self._complete_subtask(task_id, subtask.id, success, output)
            except Exception as e:
                self._complete_subtask(task_id, subtask.id, False,
                                      f"Local execution error: {e}")
        else:
            self._complete_subtask(task_id, subtask.id, True,
                                  f"Queued: {subtask.command}")

    # ------------------------------------------------------------------
    # Result handling
    # ------------------------------------------------------------------

    def on_subtask_result(self, task_id: str, subtask_id: str,
                          success: bool, output: str) -> None:
        """Handle a sub-task result from a remote node."""
        self._complete_subtask(task_id, subtask_id, success, output)

    def _complete_subtask(self, task_id: str, subtask_id: str,
                         success: bool, output: str) -> None:
        """Mark a sub-task as complete and check for task completion."""
        with self._lock:
            task = self._tasks.get(task_id)
            if not task:
                return

            for subtask in task.sub_tasks:
                if subtask.id == subtask_id:
                    subtask.status = TaskStatus.COMPLETED if success else TaskStatus.FAILED
                    subtask.result = output
                    subtask.completed_at = time.time()
                    break

        self._check_completion(task_id)

    def _check_completion(self, task_id: str) -> None:
        """Check if all sub-tasks are done and finalize the task."""
        with self._lock:
            task = self._tasks.get(task_id)
            if not task or task.is_complete:
                return

            all_done = all(
                st.status in (TaskStatus.COMPLETED, TaskStatus.FAILED)
                for st in task.sub_tasks
            )

            if not all_done:
                return

            # Aggregate results
            successes = [st for st in task.sub_tasks
                        if st.status == TaskStatus.COMPLETED]
            failures = [st for st in task.sub_tasks
                       if st.status == TaskStatus.FAILED]

            if not failures:
                task.status = TaskStatus.COMPLETED
                task.result_summary = "; ".join(st.result or "" for st in successes)
            elif successes:
                task.status = TaskStatus.COMPLETED  # Partial success
                task.result_summary = (
                    f"{len(successes)}/{len(task.sub_tasks)} succeeded. "
                    f"Errors: {'; '.join(st.result or '' for st in failures)}"
                )
            else:
                task.status = TaskStatus.FAILED
                task.result_summary = (
                    f"All {len(failures)} sub-tasks failed: "
                    f"{'; '.join(st.result or '' for st in failures)}"
                )

            task.completed_at = time.time()

            logger.info(f"Task {task_id} {task.status.value}: {task.result_summary[:120]}")

            # Fire callback
            callback = self._result_callbacks.pop(task_id, None)
            if callback:
                try:
                    callback(task)
                except Exception as e:
                    logger.warning(f"Task callback failed: {e}")

    # ------------------------------------------------------------------
    # Timeout handling
    # ------------------------------------------------------------------

    def _timeout_checker(self) -> None:
        """Periodically check for timed-out sub-tasks."""
        while self._running:
            time.sleep(5)
            with self._lock:
                now = time.time()
                for task in list(self._tasks.values()):
                    if task.is_complete:
                        continue
                    for subtask in task.sub_tasks:
                        if subtask.status == TaskStatus.RUNNING and subtask.started_at:
                            elapsed = now - subtask.started_at
                            if elapsed > self.default_timeout_s:
                                subtask.status = TaskStatus.TIMED_OUT
                                subtask.result = (
                                    f"Timed out after {elapsed:.0f}s on "
                                    f"{subtask.assigned_node or 'local'}"
                                )
                                logger.warning(f"Sub-task {subtask.id} timed out")
                    self._check_completion(task.id)

    # ------------------------------------------------------------------
    # Query methods
    # ------------------------------------------------------------------

    def get_task(self, task_id: str) -> Optional[NexusTask]:
        return self._tasks.get(task_id)

    def list_tasks(self) -> List[NexusTask]:
        return list(self._tasks.values())

    def list_active_tasks(self) -> List[NexusTask]:
        return [t for t in self._tasks.values() if not t.is_complete]

    def register_device(self, node_id: str, capabilities: dict) -> None:
        self.decomposer.register_device(node_id, capabilities)

    def remove_device(self, node_id: str) -> None:
        self.decomposer.remove_device(node_id)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _str_to_strategy(name: str) -> ExecutionStrategy:
    """Convert a strategy name string to ExecutionStrategy enum."""
    mapping = {
        "local": ExecutionStrategy.LOCAL,
        "parallelized": ExecutionStrategy.PARALLELIZED,
        "fused": ExecutionStrategy.FUSED,
        "relay_to": ExecutionStrategy.RELAY_TO,
    }
    return mapping.get(name, ExecutionStrategy.LOCAL)
