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
        self.proactive = ProactiveAssistant(self.learning_repo)
        self.vision = VisionModule(storage_dir)
        self.device_registry = DeviceRegistry()

        # Brain
        self._brain = NexusBrain(
            self.command_engine,
            history_store=ChatHistoryStore(storage_dir),
            llm_parser=self.llm_parser,
        )
        self._discovered_backend: Optional[DiscoveredBackend] = None

        # Mesh
        self.peer_store = PeerTrustStore(os.path.join(storage_dir, "peer_keys.json"))
        self.mesh: Optional[MeshManager] = None

        # Callbacks
        self._on_command: Optional[Callable[[str, CommandResult], None]] = None
        self._on_threat: Optional[Callable[[str, str], None]] = None

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

    def start(self, enable_mesh: bool = True, api_port: int = 9090) -> None:
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
            self.mesh.start()
            logger.info("Mesh networking started")

        # Start API server
        self._start_api(api_port)

        # Start proactive assistant
        self.proactive.start()

        # Scan local device capabilities
        self._scan_local_capabilities()

        logger.info("Nexus orchestrator fully started")

    def stop(self) -> None:
        """Gracefully stop all Nexus services."""
        if self.mesh:
            self.mesh.stop()
            self.mesh = None
        self.proactive.stop()
        logger.info("Nexus orchestrator stopped")

    def _on_node_changed(self) -> None:
        """Called when mesh nodes change - update device registry."""
        if not self.mesh:
            return
        for node in self.mesh.nodes.values():
            self.device_registry.register_or_update(node)
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
            return result

        # 2. LLM fallback
        llm_intent = self.llm_parser.parse(command)
        if llm_intent:
            result = self.command_engine.perform_action(llm_intent.action)
            if result.success:
                self.learning_repo.record_success(command, llm_intent.action)
            return result

        # 3. Learning-based fallback
        learned = self.learning_repo.find_similar_action(command)
        if learned:
            result = self.command_engine.perform_action(learned)
            if result.success:
                self.learning_repo.record_success(command, learned)
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

    # ------------------------------------------------------------------
    # Vision
    # ------------------------------------------------------------------

    def locate_item(self, item_description: str) -> Optional[dict]:
        """Use computer vision to locate a physical item."""
        return self.vision.locate_item(item_description)

    def query_cameras(self, query: str) -> list:
        """Query all connected cameras for information."""
        return self.vision.query_cameras(query)

    # ------------------------------------------------------------------
    # Device infrastructure
    # ------------------------------------------------------------------

    def setup_network(self, devices: list, config: dict) -> bool:
        """Auto-configure network settings for connected devices."""
        return self.device_registry.setup_network(devices, config)

    def get_device_capabilities(self) -> dict:
        """Get capabilities of all registered devices."""
        return self.device_registry.get_all_capabilities()
