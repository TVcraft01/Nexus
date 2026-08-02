# Nexus Orchestrator - Master Controller
#
# The orchestrator is the brain of Nexus. It manages:
# - Device discovery and capability registry
# - Task decomposition and distributed execution (via Rust core)
# - AI/NLP integration (brain module)
# - Security monitoring
# - API server

from __future__ import annotations

import logging
import os
import threading
import uuid
from typing import Callable, Dict, List, Optional

from nexus_server.ai.engine import CommandEngine
from nexus_server.ai.learning import LearningRepository
from nexus_server.ai.proactive import ProactiveAssistant
from nexus_server.ai.vision import VisionModule
from nexus_server.brain import NexusBrain, ChatHistoryStore
from nexus_server.brain.llm_discovery import DiscoveredBackend, best_backend, backend_status_message
from nexus_server.brain.llm_engine import LocalLLMIntentParser
from nexus_server.mesh import MeshManager, PeerTrustStore
from nexus_server.security import SecurityGuard
from nexus_server.storage import (
    SettingsRepository,
    UserRulesRepository,
    get_storage_dir,
)
from nexus_server.models import CommandAction, CommandResult, CommandStatus, MeshNode, ParsedIntent
from nexus_server.devices import DeviceRegistry
from nexus_server.orchestrator.task_executor import (
    DistributedTaskExecutor, WorkloadType, NexusTask,
)

logger = logging.getLogger("nexus.orchestrator")


class NexusOrchestrator:
    """Master orchestrator for the entire Nexus ecosystem."""

    def __init__(self, storage_dir: str = ".nexus") -> None:
        self.storage_dir = storage_dir
        os.makedirs(storage_dir, exist_ok=True)

        self.node_id = self._load_or_create_node_id()
        self.node_name = os.uname().nodename if hasattr(os, "uname") else "nexus-node"

        # Core modules
        self.security = SecurityGuard()
        self.rules_repo = UserRulesRepository()
        self.settings_repo = SettingsRepository()
        self.command_engine = CommandEngine(self.rules_repo)
        self.learning_repo = LearningRepository()
        self.llm_parser = LocalLLMIntentParser()

        # New modules
        self.proactive = ProactiveAssistant(self.learning_repo, storage_dir=storage_dir)
        self.vision = VisionModule(storage_dir)
        self.device_registry = DeviceRegistry()

        # Brain
        self._brain = NexusBrain(
            self.command_engine,
            history_store=ChatHistoryStore(storage_dir),
            llm_parser=self.llm_parser,
        )
        self._discovered_backend: Optional[DiscoveredBackend] = None

        # Phase 2: Distributed task execution
        self.task_executor = DistributedTaskExecutor(
            on_dispatch=self._dispatch_subtask,
        )

        # Mesh
        self.peer_store = PeerTrustStore(os.path.join(storage_dir, "peer_keys.json"))
        self.mesh: Optional[MeshManager] = None

        # Callbacks
        self._on_command: Optional[Callable[[str, CommandResult], None]] = None
        self._on_threat: Optional[Callable[[str, str], None]] = None

        # Streaming (lazy-init)
        self._stream_manager = None

    def _load_or_create_node_id(self) -> str:
        node_file = os.path.join(self.storage_dir, "node_id")
        if os.path.exists(node_file):
            with open(node_file, "r", encoding="utf-8") as f:
                return f.read().strip()
        node_id = f"nexus-{uuid.uuid4().hex[:8]}"
        with open(node_file, "w", encoding="utf-8") as f:
            f.write(node_id)
        return node_id

    # ------------------------------------------------------------------
    # Lifecycle
    # ------------------------------------------------------------------

    def start(self, enable_mesh: bool = True, api_port: int = 9090,
              enable_mqtt: bool = False) -> None:
        """Start all Nexus services."""
        logger.info(f"Starting Nexus orchestrator as {self.node_id}")

        if enable_mesh:
            self.mesh = MeshManager(
                node_id=self.node_id,
                node_name=self.node_name,
                peer_store=self.peer_store,
                command_engine=self.command_engine,
                on_command=self._on_command,
                on_node_changed=self._on_node_changed,
            )
            self.mesh.set_subtask_handler(self._handle_remote_subtask)
            self.mesh.start(enable_mqtt=enable_mqtt)
            logger.info("Mesh networking started" + (" (with MQTT)" if enable_mqtt else ""))

        # Wire local task execution to the command engine
        self.task_executor.set_local_executor(
            lambda cmd: self._execute_and_report(cmd)
        )

        # Start API server
        self._start_api(api_port)

        # Start proactive assistant
        self.proactive.start()

        # Start task executor
        self.task_executor.start()

        # Phase 3: Auto-detect local cameras
        self.vision.auto_detect_cameras()
        # Warm up YOLO model in background so first snapshot is fast
        threading.Thread(target=self.vision.warmup, daemon=True).start()

        # Scan local device capabilities
        self._scan_local_capabilities()

        logger.info("Nexus orchestrator fully started")

    def stop(self) -> None:
        """Gracefully stop all Nexus services."""
        if self.mesh:
            self.mesh.stop()
            self.mesh = None
        self.task_executor.stop()
        self.proactive.stop()
        if self._stream_manager:
            self._stream_manager.shutdown()
            self._stream_manager = None
        logger.info("Nexus orchestrator stopped")

    def _on_node_changed(self) -> None:
        """Called when mesh nodes change - update device registry."""
        if not self.mesh:
            return
        # Register TCP-discovered nodes
        for node in self.mesh.nodes.values():
            self.device_registry.register_or_update(node)
        # Register MQTT-discovered nodes (online only)
        for device in self.mesh.discovery.get_online_devices():
            nid = device.get("node_id", "")
            caps = device.get("capabilities", {})
            if nid and caps:
                self.device_registry.register_with_capabilities(nid, caps)
                self.task_executor.register_device(nid, caps)
        # Remove offline MQTT devices from task executor
        all_known = {d.get("node_id") for d in self.mesh.discovery.get_all_devices()}
        online = {d.get("node_id") for d in self.mesh.discovery.get_online_devices()}
        for nid in all_known - online:
            self.task_executor.remove_device(nid)
        logger.debug(f"Device registry updated: {len(self.device_registry.list_all())} devices")

    _rust_core_warned = False

    def _scan_local_capabilities(self) -> None:
        """Scan local device and register capabilities."""
        try:
            from nexus_server import _nexus_core
            caps_json = _nexus_core.scan_capabilities(self.node_id, self.node_name)
            import json
            caps = json.loads(caps_json)
            logger.info(f"Local capabilities: score={caps.get('capability_score', '?')}, "
                       f"class={caps.get('device_class', '?')}")
        except ImportError:
            if not NexusOrchestrator._rust_core_warned:
                NexusOrchestrator._rust_core_warned = True
                logger.info(
                    "Rust core not available - using Python fallback. "
                    "For full performance, build the Rust core: cd core && cargo build --release"
                )
            self._python_capability_scan()

    def _python_capability_scan(self) -> None:
        """Python fallback for capability scanning."""
        import platform
        import os

        caps = {
            "node_id": self.node_id,
            "hostname": self.node_name,
            "device_class": "desktop" if platform.system() != "Android" else "phone",
            "os": {
                "name": platform.system(),
                "version": platform.version(),
                "arch": platform.machine(),
            },
        }

        # Detect RAM
        try:
            with open("/proc/meminfo", "r") as f:
                for line in f:
                    if line.startswith("MemTotal:"):
                        caps["ram_mb"] = int(line.split()[1]) // 1024
                        break
        except Exception:
            caps["ram_mb"] = 1024

        logger.info(f"Local capabilities (Python): {caps}")

    # ------------------------------------------------------------------
    # API server
    # ------------------------------------------------------------------

    def _start_api(self, port: int) -> None:
        """Start the local API server (WebSocket + REST)."""
        try:
            from nexus_server.api import start_api_server
            start_api_server(self, port)
            logger.info(f"API server started on port {port}")
        except ImportError as e:
            logger.debug(f"API server not available: {e}")
        except Exception as e:
            logger.warning(f"Failed to start API server: {e}")

    # ------------------------------------------------------------------
    # Command processing
    # ------------------------------------------------------------------

    def execute_command(self, input_text: str) -> CommandResult:
        """Full pipeline: security scan → parse → execute."""
        scan = self.security.scan(input_text)
        if scan.rejected:
            return CommandResult(
                False, scan.reason,
                CommandAction.Rejected(scan.reason),
                CommandStatus.FAILED,
                original_input=input_text,
            )

        command = scan.command_string

        # 1. Fast rule path
        intent = self.command_engine.parse_command_intent(command)
        if intent and intent.is_confident():
            result = self.command_engine.perform_action(intent.action)
            if result.success:
                self.learning_repo.record_success(command, intent.action)
                self.proactive.record_action(command, intent.action)
            return result

        # 2. LLM fallback
        llm_intent = self.llm_parser.parse(command)
        if llm_intent:
            result = self.command_engine.perform_action(llm_intent.action)
            if result.success:
                self.learning_repo.record_success(command, llm_intent.action)
                self.proactive.record_action(command, llm_intent.action)
            return result

        # 3. Learning-based fallback
        learned = self.learning_repo.find_similar_action(command)
        if learned:
            result = self.command_engine.perform_action(learned)
            if result.success:
                self.learning_repo.record_success(command, learned)
                self.proactive.record_action(command, learned)
            return CommandResult(
                result.success,
                f"Learned: {result.message}",
                learned,
                result.status,
                original_input=command,
            )

        # 4. Human help
        return CommandResult(
            False,
            f"I don't know how to handle '{command}'. Would you like to teach me?",
            CommandAction.Unknown(command),
            CommandStatus.FAILED,
            requires_intern_choice=True,
            choices=["Teach", "Cancel"],
            original_input=command,
        )

    # ------------------------------------------------------------------
    # AI / Chat
    # ------------------------------------------------------------------

    @property
    def backend(self) -> Optional[DiscoveredBackend]:
        if self._discovered_backend is None:
            self._discovered_backend = best_backend()
        return self._discovered_backend

    def refresh_backend(self) -> Optional[DiscoveredBackend]:
        self._discovered_backend = best_backend()
        return self._discovered_backend

    def chat(self, user_text: str) -> "BrainResponse":
        """Process a conversational message through the brain."""
        result = self._brain.chat(user_text, backend=self.backend)
        # If the chat resulted in a command action, handle it
        if result.action and not result.requires_confirmation:
            self.proactive.record_action(user_text, result.action)
        return result

    def confirm_command(self) -> "BrainResponse":
        backend = self.backend
        if backend is None:
            from nexus_server.brain import BrainResponse
            return BrainResponse(text="No local LLM server detected.")
        return self._brain.confirm_pending_command(backend)

    def chat_status(self) -> str:
        return backend_status_message(self.backend)

    # ------------------------------------------------------------------
    # Teaching / Learning
    # ------------------------------------------------------------------

    def teach_rule(self, input_text: str, action_name: str, payload: str = "") -> bool:
        action = CommandAction(action_name, self._payload_to_args(action_name, payload))
        return self.command_engine.teach_rule(input_text, action)

    @staticmethod
    def _payload_to_args(action_name: str, payload: str) -> dict:
        """Convert payload string to action args."""
        # Reuse the same logic from the original service.py
        if action_name == "SET_VOLUME":
            return {"percent": int(payload) if payload.isdigit() else 50}
        if action_name == "OPEN_WEBSITE":
            return {"url": payload}
        if action_name == "WEB_SEARCH":
            return {"query": payload}
        if action_name == "TAKE_NOTE":
            return {"content": payload}
        if action_name == "SET_TIMER":
            return {"seconds": int(payload) if payload.isdigit() else 60}
        if action_name == "PLAY_MEDIA":
            return {"query": payload}
        return {}

    # ------------------------------------------------------------------
    # Mesh / Device management
    # ------------------------------------------------------------------

    @property
    def discovered_nodes(self) -> List[MeshNode]:
        if not self.mesh:
            return []
        return list(self.mesh.nodes.values())

    def pair_with_node(self, peer_id: str, pin: str) -> bool:
        if not self.mesh:
            return False
        try:
            self.mesh.pair_with_pin(peer_id, pin)
            return True
        except Exception as e:
            logger.error(f"Pairing failed: {e}")
            return False

    def unpair_node(self, peer_id: str) -> None:
        self.peer_store.remove_peer(peer_id)

    def relay_command(self, node: MeshNode, command: str) -> Optional[CommandResult]:
        if not self.mesh:
            return None
        return self.mesh.send_command(node, command)

    # ------------------------------------------------------------------
    # Security
    # ------------------------------------------------------------------

    def on_command_callback(self, callback: Callable[[str, CommandResult], None]) -> None:
        self._on_command = callback
        if self.mesh:
            self.mesh.on_command = callback

    def on_threat_callback(self, callback: Callable[[str, str], None]) -> None:
        self._on_threat = callback

    def get_security_alerts(self) -> list:
        return self.security.get_alerts()

    # ------------------------------------------------------------------
    # Proactive AI
    # ------------------------------------------------------------------

    def get_proactive_suggestions(self) -> list:
        """Get proactive suggestions based on learned routines."""
        return self.proactive.get_suggestions()

    def get_todays_routine(self) -> list:
        """Get the predicted routine for today."""
        return self.proactive.get_todays_routine()

    def get_reminders(self) -> list:
        """Get recent reminder notifications."""
        return self.proactive.get_notifications()

    def dismiss_reminder(self, index: int) -> bool:
        """Dismiss a reminder notification."""
        return self.proactive.dismiss_notification(index)

    def send_test_reminder(self) -> bool:
        """Send a test notification."""
        return self.proactive.send_test_notification()

    def get_insights(self) -> list:
        """Get behavioral insights."""
        return self.proactive.get_insights()

    def get_streaks(self) -> list:
        """Get current action streaks."""
        return self.proactive.get_streaks()

    def predict_next(self) -> Optional[dict]:
        """Predict the user's next most likely action."""
        return self.proactive.predict_next_action()

    # ------------------------------------------------------------------
    # Vision
    # ------------------------------------------------------------------

    def locate_item(self, item_description: str) -> Optional[dict]:
        """Use computer vision to locate a physical item."""
        return self.vision.locate_item(item_description)

    def query_cameras(self, query: str) -> list:
        """Query all connected cameras for information."""
        return self.vision.query_cameras(query)

    def snapshot_camera(self, camera_id: str) -> Optional[dict]:
        """Capture a snapshot from a specific camera."""
        return self.vision.capture_snapshot(camera_id)

    def list_cameras(self) -> list:
        """List all registered cameras."""
        return self.vision.list_cameras()

    def search_cameras(self, query: str) -> list:
        """Search all cameras for objects matching a query."""
        return self.vision.query_cameras(query)

    def vision_status(self) -> dict:
        """Get vision module status."""
        return self.vision.status()

    def snapshot_image(self, camera_id: str) -> Optional[bytes]:
        """Capture a raw JPEG snapshot (for image endpoint)."""
        return self.vision.capture_snapshot_raw(camera_id)

    def warmup_vision(self) -> dict:
        """Manually trigger YOLO warmup."""
        return self.vision.warmup()

    # ------------------------------------------------------------------
    # Streaming
    # ------------------------------------------------------------------

    @property
    def stream_manager(self):
        """Lazy-init the camera streaming manager."""
        if self._stream_manager is None:
            from nexus_server.api.streaming import CameraStreamManager
            self._stream_manager = CameraStreamManager(self.vision)
        return self._stream_manager

    # ------------------------------------------------------------------
    # Device infrastructure
    # ------------------------------------------------------------------

    def setup_network(self, devices: list, config: dict) -> bool:
        """Auto-configure network settings for connected devices."""
        return self.device_registry.setup_network(devices, config)

    def get_device_capabilities(self) -> dict:
        """Get capabilities of all registered devices."""
        return self.device_registry.get_all_capabilities()

    # ------------------------------------------------------------------
    # Phase 2: Distributed Task Execution
    # ------------------------------------------------------------------

    def _execute_and_report(self, command: str) -> tuple:
        """Execute a command and return (success, message). Used by task executor."""
        result = self.command_engine.execute_command(command)
        return (result.success, result.message)

    def submit_task(
        self,
        description: str,
        workload_type: str = "command",
        priority: int = 5,
    ) -> dict:
        """Submit a task for distributed execution across the mesh."""
        # Register available device capabilities with executor
        if self.mesh:
            for device in self.mesh.discovery.get_online_devices():
                nid = device.get("node_id", "")
                caps = device.get("capabilities", {})
                if nid and caps:
                    self.task_executor.register_device(nid, caps)

        wl = WorkloadType(workload_type) if workload_type in [
            w.value for w in WorkloadType
        ] else WorkloadType.COMMAND

        task = self.task_executor.submit(description, wl, priority)
        return {
            "task_id": task.id,
            "status": task.status.value,
            "strategy": task.strategy.value,
            "sub_tasks": len(task.sub_tasks),
        }

    def get_task(self, task_id: str) -> Optional[dict]:
        """Get status of a distributed task."""
        task = self.task_executor.get_task(task_id)
        if not task:
            return None
        return self._task_to_dict(task)

    def list_tasks(self) -> list:
        """List all distributed tasks."""
        return [self._task_to_dict(t) for t in self.task_executor.list_tasks()]

    @staticmethod
    def _task_to_dict(task: NexusTask) -> dict:
        return {
            "id": task.id,
            "description": task.description,
            "status": task.status.value,
            "strategy": task.strategy.value,
            "progress": round(task.progress, 2),
            "sub_tasks": [
                {
                    "id": st.id,
                    "status": st.status.value,
                    "assigned_node": st.assigned_node,
                    "result": st.result,
                }
                for st in task.sub_tasks
            ],
            "result_summary": task.result_summary,
        }

    def _dispatch_subtask(self, node_id: str, subtask) -> bool:
        """Dispatch a sub-task to a remote node via mesh/MQTT."""
        if not self.mesh:
            return False

        payload = {
            "task_id": getattr(subtask, "id", str(subtask)),
            "id": getattr(subtask, "id", str(subtask)),
            "command": getattr(subtask, "command", ""),
            "workload_type": getattr(subtask, "workload_type", WorkloadType.COMMAND),
            "estimated_cost": getattr(subtask, "estimated_cost", 1.0),
        }

        # Try MQTT first, then TCP
        if self.mesh.mqtt.is_available:
            return self.mesh.mqtt.dispatch_subtask(node_id, payload, self.node_id)

        # Fallback: try direct TCP
        for node in self.discovered_nodes:
            if node.id == node_id:
                self.mesh.send_command(node, payload.get("command", ""))
                return True

        return False

    def _handle_remote_subtask(self, sender_id: str, payload: dict) -> None:
        """Handle a sub-task received from a remote node, or a result coming back."""
        task_id = payload.get("task_id", "")
        subtask_id = payload.get("subtask_id", "")
        command = payload.get("command", "")

        # If this is a result coming back, forward to task executor
        if "success" in payload and command == "" and task_id:
            self.task_executor.on_subtask_result(
                task_id,
                subtask_id or f"{task_id}-remote",
                payload.get("success", False),
                payload.get("output", ""),
            )
            return

        # Otherwise, execute the sub-task locally
        result = self.command_engine.execute_command(command)

        # Send result back via MQTT (include subtask_id so originator can match)
        if self.mesh:
            self.mesh.mqtt.send_result(
                sender_id, task_id, result.success, result.message,
                subtask_id=subtask_id,
            )

    # ------------------------------------------------------------------
    # Phase 2: MQTT / Network
    # ------------------------------------------------------------------

    def enable_mqtt(self, broker_host: str = "localhost", broker_port: int = 1883) -> bool:
        """Enable MQTT bridge for cross-network communication."""
        if not self.mesh:
            logger.warning("Cannot enable MQTT — mesh not started")
            return False
        from nexus_server.mesh.discovery import build_local_capabilities
        caps = build_local_capabilities(self.node_id, self.node_name)
        return self.mesh.mqtt.start(local_capabilities=caps)

    def get_network_summary(self) -> dict:
        """Get a summary of the device network, including MQTT status."""
        if not self.mesh:
            return {"total_devices": 0, "can_fuse": False, "mqtt_available": False}
        summary = self.mesh.discovery.get_network_summary()
        # Add MQTT bridge status
        mqtt_s = self.mesh.mqtt.status
        summary["mqtt_available"] = self.mesh.mqtt.is_available
        summary["mqtt_connected"] = mqtt_s["connected"]
        summary["mqtt_running"] = mqtt_s["running"]
        return summary

    def mqtt_status(self) -> dict:
        """Get MQTT bridge status."""
        if not self.mesh:
            return {"available": False, "connected": False, "running": False}
        return self.mesh.mqtt.status
