"""Service orchestration for the Linux desktop node."""

from __future__ import annotations

import logging
import os
import platform
from typing import Callable, List, Optional

from .brain import BrainResponse, ChatHistoryStore, NexusBrain
from .command_engine import ZeroLLMCommandEngine
from .llm_discovery import DiscoveredBackend, best_backend, backend_status_message
from .llm_engine import LocalLLMIntentParser
from .mesh import MeshManager, PeerTrustStore
from .models import CommandAction, CommandResult, MeshNode, ParsedIntent, ThreatLevel
from .rules import UserRulesRepository
from .security_guard import SecurityGuard


logger = logging.getLogger(__name__)


class NexusService:
    """High-level service that glues the command engine, mesh, and security."""

    def __init__(self, storage_dir: str = ".nexus") -> None:
        self.storage_dir = storage_dir
        os.makedirs(storage_dir, exist_ok=True)
        self.node_id = self._generate_node_id()
        self.node_name = platform.node() or "nexus-linux"
        self.security = SecurityGuard()
        self.rules_repo = UserRulesRepository(os.path.join(storage_dir, "user_dialect_rules.json"))
        self.command_engine = ZeroLLMCommandEngine(self.rules_repo)
        self.llm_parser = LocalLLMIntentParser()
        self.peer_store = PeerTrustStore(os.path.join(storage_dir, "peer_keys.json"))
        self.mesh: Optional[MeshManager] = None
        self._on_command: Optional[Callable[[str, CommandResult], None]] = None
        self.qr_pairing_pin: Optional[str] = None
        self._brain = NexusBrain(
            self.command_engine,
            history_store=ChatHistoryStore(storage_dir),
            llm_parser=self.llm_parser,
        )
        self._discovered_backend: Optional[DiscoveredBackend] = None

    @property
    def discovered_nodes(self) -> List[MeshNode]:
        if not self.mesh:
            return []
        return list(self.mesh.nodes.values())

    def _generate_node_id(self) -> str:
        node_file = os.path.join(self.storage_dir, "node_id")
        if os.path.exists(node_file):
            try:
                with open(node_file, "r", encoding="utf-8") as f:
                    return f.read().strip()
            except Exception:
                pass
        import uuid
        node_id = f"nexus-linux-{uuid.uuid4().hex[:8]}"
        with open(node_file, "w", encoding="utf-8") as f:
            f.write(node_id)
        return node_id

    def start(self) -> None:
        self.mesh = MeshManager(
            node_id=self.node_id,
            node_name=self.node_name,
            peer_store=self.peer_store,
            command_engine=self.command_engine,
            on_command=self._on_command,
            on_node_changed=self._on_node_changed,
        )
        self.mesh.start()
        logger.info("Nexus service started as %s", self.node_id)

    def stop(self) -> None:
        if self.mesh:
            self.mesh.stop()
            self.mesh = None

    def on_command(self, callback: Callable[[str, CommandResult], None]) -> None:
        self._on_command = callback
        if self.mesh:
            self.mesh.on_command = callback

    def _on_node_changed(self) -> None:
        self._maybe_auto_pair_with_qr()

    def set_qr_pairing_pin(self, pin: Optional[str]) -> None:
        self.qr_pairing_pin = pin

    def _maybe_auto_pair_with_qr(self) -> None:
        pin = self.qr_pairing_pin
        if not pin or not self.mesh:
            return
        for node in self.discovered_nodes:
            if not self.is_paired(node.id):
                try:
                    self.pair_with_node(node.id, pin)
                except Exception:
                    pass

    # ------------------------------------------------------------------
    # Conversational brain
    # ------------------------------------------------------------------
    @property
    def backend(self) -> Optional[DiscoveredBackend]:
        if self._discovered_backend is None:
            self._discovered_backend = best_backend()
        return self._discovered_backend

    def refresh_backend(self) -> Optional[DiscoveredBackend]:
        self._discovered_backend = best_backend()
        return self._discovered_backend

    def chat(self, user_text: str, auto_execute: bool = True) -> BrainResponse:
        return self._brain.chat(user_text, backend=self.backend, auto_execute=auto_execute)

    def confirm_pending_command(self) -> BrainResponse:
        backend = self.backend
        if backend is None:
            return BrainResponse(text="No local LLM server detected.")
        return self._brain.confirm_pending_command(backend)

    def clear_chat(self) -> None:
        self._brain.history.clear()

    def chat_status(self) -> str:
        return backend_status_message(self.backend)

    def execute_local_command(self, input_text: str) -> CommandResult:
        scan = self.security.scan(input_text)
        if scan.rejected:
            return CommandResult(
                False,
                scan.reason,
                CommandAction.Rejected(scan.reason),
                requires_intern_choice=True,
                choices=["Cancel"],
                original_input=input_text,
            )

        command = scan.command_string

        # 1. Fast rule path.
        intent = self.command_engine.parse_command_intent(command)
        if intent and intent.is_confident():
            return self._execute_intent(intent)

        # 2. LLM fallback.
        llm_intent = self.llm_parser.parse(command)
        if llm_intent:
            return self._execute_intent(llm_intent)

        # 3. Human help fallback.
        return CommandResult(
            False,
            f"I don't know how to handle '{command}'. Would you like to teach me?",
            CommandAction.Unknown(command),
            requires_intern_choice=True,
            choices=["Teach", "Cancel"],
            original_input=command,
        )

    def _execute_intent(self, intent: ParsedIntent) -> CommandResult:
        # Execute the already-parsed action directly. Re-parsing would cause
        # LLM/user-rule intents to fall through to the human-help path again.
        result = self.command_engine._perform_action(intent.action)
        # Preserve the source for logging/diagnostics.
        if intent.source != "regex" and result.success:
            result.message = f"{result.message} ({intent.source})"
        return result

    def teach_rule(self, input_text: str, action_name: str, payload: str = "") -> bool:
        """Store a new user dialect rule so the next matching input is handled instantly."""
        action = CommandAction(action_name, self._payload_to_args(action_name, payload))
        return self.command_engine.teach_rule(input_text, action)

    @staticmethod
    def _payload_to_args(action_name: str, payload: str) -> dict:
        """Convert the stored payload string into CommandAction args."""
        if action_name == "TOGGLE_WIFI":
            return {"enable": payload.lower() in ("true", "1", "yes", "on")}
        if action_name == "TOGGLE_BLUETOOTH":
            return {"enable": payload.lower() in ("true", "1", "yes", "on")}
        if action_name == "SET_BRIGHTNESS":
            return {"level": int(payload) if payload.isdigit() else 50}
        if action_name == "SET_VOLUME":
            return {"percent": int(payload) if payload.isdigit() else 50}
        if action_name == "ADJUST_VOLUME":
            return {"delta": int(payload) if payload.lstrip("-").isdigit() else 0}
        if action_name == "MUTE_VOLUME":
            return {}
        if action_name == "PLAY_MEDIA":
            return {"query": payload}
        if action_name == "PLAY_MEDIA_APP":
            parts = payload.split("|", 1)
            return {"query": parts[0], "app_name": parts[1] if len(parts) > 1 else ""}
        if action_name == "MEDIA_CONTROL":
            return {"command": payload}
        if action_name == "PAUSE_MEDIA":
            return {"query": payload}
        if action_name == "OPEN_APP":
            return {"package_name": payload}
        if action_name == "OPEN_WEBSITE":
            return {"url": payload}
        if action_name == "WEB_SEARCH":
            return {"query": payload}
        if action_name == "OPEN_SETTINGS":
            return {"page": payload or "settings"}
        if action_name == "MESH_RELAY":
            return {"payload": payload}
        if action_name == "TOGGLE_FLASHLIGHT":
            return {"enable": payload.lower() in ("true", "1", "yes", "on")}
        if action_name == "SET_TIMER":
            return {"seconds": int(payload) if payload.isdigit() else 60}
        if action_name == "SET_ALARM":
            parts = payload.split("|", 1)
            return {"hour": int(parts[0]) if parts[0].isdigit() else 7, "minute": int(parts[1]) if len(parts) > 1 and parts[1].isdigit() else 0}
        if action_name == "TAKE_NOTE":
            return {"content": payload}
        if action_name == "ROLL_DICE":
            return {"sides": int(payload) if payload.isdigit() else 6}
        if action_name == "FLIP_COIN":
            return {}
        if action_name == "TOGGLE_DND":
            return {"enable": payload.lower() in ("true", "1", "yes", "on")}
        if action_name == "NAVIGATE":
            return {"destination": payload}
        if action_name == "OPEN_CALENDAR":
            return {}
        if action_name == "CALCULATE":
            return {"expression": payload}
        if action_name == "SMART_HOME":
            parts = payload.split("|", 2)
            value = parts[2] if len(parts) > 2 and parts[2].lower() != "none" and parts[2] != "" else None
            return {"device": parts[0] if parts else "", "operation": parts[1] if len(parts) > 1 else "SET_STATE", "value": value}
        if action_name == "LIST_ACTION":
            parts = payload.split("|", 1)
            return {"item": parts[0], "list_name": parts[1] if len(parts) > 1 else "todo"}
        if action_name == "SET_REMINDER":
            return {"task": payload}
        if action_name == "SEARCH_INFO":
            parts = payload.split("|", 1)
            return {"query": parts[0], "search_type": parts[1] if len(parts) > 1 else "Define"}
        if action_name == "OPEN_CAMERA":
            return {"is_selfie": payload.lower() in ("true", "1", "yes", "on")}
        if action_name == "RECORD_VIDEO":
            return {}
        if action_name == "CALL_CONTACT":
            return {"contact": payload}
        if action_name == "SEND_TEXT":
            parts = payload.split("|", 1)
            return {"contact": parts[0], "message": parts[1] if len(parts) > 1 else None}
        if action_name == "SEND_EMAIL":
            return {"recipient": payload}
        if action_name == "CANCEL_ALARM_TIMER":
            return {}
        if action_name == "GET_TIME_DATE":
            return {}
        if action_name == "GET_BATTERY_STATUS":
            return {}
        if action_name == "GET_NEXT_ALARM":
            return {}
        if action_name == "GET_JOKE":
            return {}
        if action_name == "GET_WEATHER":
            return {}
        if action_name == "GET_TODAY_SCHEDULE":
            return {}
        return {}

    def pair_with_node(self, peer_id: str, pin: str) -> bool:
        if not self.mesh:
            return False
        try:
            self.mesh.pair_with_pin(peer_id, pin)
            return True
        except Exception as exc:
            logger.error("Pairing failed: %s", exc)
            return False

    def unpair_node(self, peer_id: str) -> None:
        self.peer_store.remove_peer(peer_id)

    def is_paired(self, peer_id: str) -> bool:
        return self.peer_store.is_paired(peer_id)

    def relay_command(self, node: MeshNode, command: str) -> Optional[CommandResult]:
        if not self.mesh:
            return None
        return self.mesh.send_command(node, command)
