"""Nexus conversational brain.

Provides a natural-language chat loop on top of a local LLM.  The brain
maintains conversation history, asks the LLM to decide whether to chat or
execute a command, and optionally feeds command results back to the LLM so
it can summarize them for the user.
"""

from __future__ import annotations

import json
import logging
import os
import re
import threading
from dataclasses import dataclass, field
from typing import Any, Callable, Dict, List, Optional

from .command_engine import ZeroLLMCommandEngine
from .llm_engine import LocalLLMIntentParser
from .llm_discovery import DiscoveredBackend, best_backend
from .models import CommandAction, CommandResult, SAFE_COMMANDS

logger = logging.getLogger(__name__)


@dataclass
class ChatMessage:
    role: str  # "user", "assistant", "system"
    content: str
    action: Optional[str] = None


@dataclass
class BrainResponse:
    text: str
    action: Optional[CommandAction] = None
    action_result: Optional[CommandResult] = None
    requires_confirmation: bool = False


class NexusBrain:
    """Conversational wrapper around a local LLM and the command engine."""

    def __init__(
        self,
        command_engine: ZeroLLMCommandEngine,
        history_store: Optional["ChatHistoryStore"] = None,
        llm_parser: Optional[LocalLLMIntentParser] = None,
    ):
        self.command_engine = command_engine
        self.history = history_store or ChatHistoryStore()
        self.llm_parser = llm_parser or LocalLLMIntentParser()
        self._lock = threading.Lock()

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------
    def chat(
        self,
        user_text: str,
        backend: Optional[DiscoveredBackend] = None,
        auto_execute: bool = True,
    ) -> BrainResponse:
        """Process a user message and return a response.

        If the LLM decides to execute a command, the command is run and the
        result is optionally summarized by the LLM.  State-changing commands
        may require user confirmation before running.
        """
        backend = backend or best_backend()
        if backend is None:
            return BrainResponse(
                text="I can't find a local LLM server. Please start Ollama, LM Studio, or llama.cpp first."
            )

        with self._lock:
            self.history.add(ChatMessage("user", user_text))

        messages = self._build_messages()
        raw = self._call_llm(backend, messages)
        if raw is None:
            return BrainResponse(text="I'm having trouble reaching the local LLM right now.")

        parsed = self._parse_response(raw)
        if parsed is None:
            return BrainResponse(text=raw)

        if parsed.get("type") == "command":
            return self._handle_command(parsed, backend, auto_execute=auto_execute)

        text = parsed.get("content") or raw
        with self._lock:
            self.history.add(ChatMessage("assistant", text))
        return BrainResponse(text=text)

    def confirm_pending_command(self, backend: DiscoveredBackend) -> BrainResponse:
        """Execute a previously queued command that required confirmation."""
        pending = self.history.pop_pending_action()
        if pending is None:
            return BrainResponse(text="No pending command to confirm.")
        action = pending["action"]
        result = self.command_engine.perform_action(action)
        with self._lock:
            self.history.add(ChatMessage("system", f"Command result: {result.message}"))
        summary = self._summarize_result(backend, result)
        with self._lock:
            self.history.add(ChatMessage("assistant", summary))
        return BrainResponse(
            text=summary, action=action, action_result=result, requires_confirmation=False
        )

    # ------------------------------------------------------------------
    # LLM interaction
    # ------------------------------------------------------------------
    MAX_CONTEXT_CHARS = 3000

    def _build_messages(self) -> List[Dict[str, str]]:
        system = self._system_prompt()
        messages: List[Dict[str, str]] = [{"role": "system", "content": system}]
        budget = max(0, self.MAX_CONTEXT_CHARS - len(system))
        selected: List[ChatMessage] = []
        used = 0
        for msg in reversed(self.history.recent(max_turns=200)):
            if used + len(msg.content) > budget:
                break
            selected.append(msg)
            used += len(msg.content)
        for msg in reversed(selected):
            messages.append({"role": msg.role, "content": msg.content})
        return messages

    def _call_llm(self, backend: DiscoveredBackend, messages: List[Dict[str, str]]) -> Optional[str]:
        try:
            import urllib.request
            import urllib.error

            payload = {
                "model": backend.selected_model or (backend.models[0] if backend.models else "local"),
                "messages": messages,
                "temperature": 0.3,
                "max_tokens": 512,
            }
            req = urllib.request.Request(
                backend.backend.chat_endpoint,
                data=json.dumps(payload).encode("utf-8"),
                headers={"Content-Type": "application/json"},
                method="POST",
            )
            with urllib.request.urlopen(req, timeout=30.0) as resp:
                data = json.loads(resp.read().decode("utf-8"))
            choices = data.get("choices", []) if isinstance(data, dict) else []
            if not choices:
                return None
            message = choices[0].get("message", {}) if isinstance(choices[0], dict) else {}
            content = message.get("content", "")
            return str(content).strip() if content else None
        except Exception as exc:
            logger.warning("LLM call failed: %s", exc)
            return None

    def _parse_response(self, content: str) -> Optional[Dict[str, Any]]:
        try:
            cleaned = re.sub(r"^```(?:json)?\s*", "", content.strip(), flags=re.IGNORECASE)
            cleaned = re.sub(r"\s*```$", "", cleaned)
            data = json.loads(cleaned)
            if isinstance(data, dict):
                return data
        except json.JSONDecodeError:
            pass
        return None

    # ------------------------------------------------------------------
    # Action construction
    # ------------------------------------------------------------------
    def _build_action(self, name: str, args: Dict[str, Any]) -> Optional[CommandAction]:
        try:
            return LocalLLMIntentParser.build_action(name, args)
        except Exception as exc:
            logger.warning("Could not build action %s with args %s: %s", name, args, exc)
            return None

    # ------------------------------------------------------------------
    # Command handling
    # ------------------------------------------------------------------
    def _handle_command(
        self,
        parsed: Dict[str, Any],
        backend: DiscoveredBackend,
        auto_execute: bool,
    ) -> BrainResponse:
        action_name = str(parsed.get("action", "")).upper()
        args = parsed.get("args", {}) or {}
        action = self._build_action(action_name, args)

        if action is None:
            return BrainResponse(text=parsed.get("content") or "I understood you wanted to run a command, but I don't know which one.")

        if not auto_execute or self._requires_confirmation(action):
            self.history.queue_pending_action(action)
            friendly = parsed.get("content") or f"I'll {self._action_description(action)}. Approve?"
            return BrainResponse(text=friendly, action=action, requires_confirmation=True)

        result = self.command_engine.perform_action(action)
        with self._lock:
            self.history.add(ChatMessage("system", f"Command result: {result.message}"))
        summary = self._summarize_result(backend, result, action)
        with self._lock:
            self.history.add(ChatMessage("assistant", summary))
        return BrainResponse(text=summary, action=action, action_result=result)

    def _summarize_result(self, backend: DiscoveredBackend, result: CommandResult, action: Optional[CommandAction] = None) -> str:
        # Ask the LLM to summarize; fall back to the raw message.
        messages = [
            {"role": "system", "content": "Summarize the following command result in one short, friendly sentence."},
            {"role": "user", "content": f"Command result: {result.message}"},
        ]
        try:
            raw = self._call_llm(backend, messages)
            if raw:
                parsed = self._parse_response(raw)
                if parsed and "content" in parsed:
                    return parsed["content"]
                if raw.strip():
                    return raw.strip()
        except Exception:
            pass
        return result.message

    # ------------------------------------------------------------------
    # Action reconstruction (mirror of llm_engine._build_action)
    # ------------------------------------------------------------------
    @staticmethod
    def _bool(value: Any) -> bool:
        return str(value).lower() in ("true", "1", "yes", "on")

    # ------------------------------------------------------------------
    # Safety: which commands require explicit user confirmation
    # ------------------------------------------------------------------
    def _requires_confirmation(self, action: CommandAction) -> bool:
        return action.name not in SAFE_COMMANDS

    def _action_description(self, action: CommandAction) -> str:
        return f"run {action.name}"

    # ------------------------------------------------------------------
    # System prompt
    # ------------------------------------------------------------------
    @staticmethod
    def _system_prompt() -> str:
        return load_prompt_from_file() or DEFAULT_SYSTEM_PROMPT


# ------------------------------------------------------------------------------
# Shared prompt utilities
# ------------------------------------------------------------------------------
DEFAULT_SYSTEM_PROMPT = (
    "You are Nexus, a helpful local voice assistant. The user talks to you naturally.\n"
    "You can either reply conversationally OR run one of the supported commands.\n"
    "Always respond with a single JSON object exactly in this format:\n"
    '{"type": "chat", "content": "Your natural reply here."}\n'
    "or\n"
    '{"type": "command", "content": "What you are about to do", "action": "ACTION_NAME", "args": {...}}\n\n'
    "When type is 'command', action must be one of these names and args must match:\n"
    "OPEN_APP: {package_name: string}\n"
    "OPEN_WEBSITE: {url: string}\n"
    "WEB_SEARCH: {query: string}\n"
    "TOGGLE_WIFI, TOGGLE_BLUETOOTH, TOGGLE_FLASHLIGHT, TOGGLE_DND: {enable: bool}\n"
    "SET_BRIGHTNESS: {level: int}\n"
    "SET_VOLUME: {percent: int}, ADJUST_VOLUME: {delta: int}, MUTE_VOLUME: {}\n"
    "PLAY_MEDIA: {query: string}, PLAY_MEDIA_APP: {query: string, app_name: string}\n"
    "PAUSE_MEDIA: {query?: string}, MEDIA_CONTROL: {command: string}\n"
    "SET_TIMER: {seconds: int, label?: string}\n"
    "SET_ALARM: {hour: int, minute: int, label?: string, repeating?: bool}\n"
    "TAKE_NOTE: {content: string}\n"
    "ROLL_DICE: {sides?: int}, FLIP_COIN: {}\n"
    "NAVIGATE: {destination: string}\n"
    "OPEN_CALENDAR: {}, CALCULATE: {expression: string}\n"
    "SMART_HOME: {device: string, operation: string, value?: string|null}\n"
    "LIST_ACTION: {item: string, list_name: string}\n"
    "SET_REMINDER: {task: string}\n"
    "SEARCH_INFO: {query: string, search_type: string}\n"
    "OPEN_CAMERA: {is_selfie: bool}, RECORD_VIDEO: {}\n"
    "CALL_CONTACT: {contact: string}, SEND_TEXT: {contact: string, message?: string}\n"
    "SEND_EMAIL: {recipient: string}\n"
    "CANCEL_ALARM_TIMER: {}\n"
    "GET_TIME_DATE, GET_BATTERY_STATUS, GET_NEXT_ALARM, GET_JOKE, GET_WEATHER, GET_TODAY_SCHEDULE\n"
    "If the request does not match any command, use type 'chat'.\n"
)


def load_prompt_from_file() -> Optional[str]:
    """Load the shared system prompt from the repo root if available."""
    candidates = [
        # Running from the git checkout: desktop/nexus/ -> ../../shared/prompts
        os.path.join(os.path.dirname(__file__), "..", "..", "shared", "prompts", "nexus_brain_system_prompt.md"),
        # Fallback relative to the current working directory.
        os.path.join(os.getcwd(), "shared", "prompts", "nexus_brain_system_prompt.md"),
    ]
    for path in candidates:
        try:
            with open(path, "r", encoding="utf-8") as f:
                return f.read()
        except (FileNotFoundError, OSError, IOError):
            continue
    return None


# ------------------------------------------------------------------------------
# Simple in-memory + persisted chat history store
# ------------------------------------------------------------------------------
class ChatHistoryStore:
    """Minimal chat history store. Persists to a JSON file in storage_dir."""

    def __init__(self, storage_dir: str = ".nexus"):
        self.storage_dir = storage_dir
        os.makedirs(storage_dir, exist_ok=True)
        self._file = os.path.join(storage_dir, "chat_history.json")
        self._messages: List[ChatMessage] = []
        self._pending_action: Optional[Dict[str, Any]] = None
        self._load()

    def add(self, message: ChatMessage) -> None:
        self._messages.append(message)
        self._trim()
        self._save()

    def recent(self, max_turns: int = 10) -> List[ChatMessage]:
        return self._messages[-max_turns * 2 :]

    def queue_pending_action(self, action: CommandAction) -> None:
        self._pending_action = {"action": action}

    def pop_pending_action(self) -> Optional[Dict[str, Any]]:
        action = self._pending_action
        self._pending_action = None
        return action

    def clear(self) -> None:
        self._messages.clear()
        self._pending_action = None
        self._save()

    def _trim(self, max_messages: int = 200) -> None:
        if len(self._messages) > max_messages:
            self._messages = self._messages[-max_messages:]

    def _load(self) -> None:
        if not os.path.exists(self._file):
            return
        try:
            with open(self._file, "r", encoding="utf-8") as f:
                data = json.load(f)
            self._messages = [ChatMessage(**m) for m in data.get("messages", [])]
            pending = data.get("pending_action")
            if pending and "action" in pending:
                act_data = pending["action"]
                pending["action"] = CommandAction(
                    name=act_data.get("name", ""),
                    args=act_data.get("args", {}),
                )
            self._pending_action = pending
        except Exception as exc:
            logger.warning("Failed to load chat history: %s", exc)

    def _save(self) -> None:
        try:
            pending_to_save: Optional[Dict[str, Any]] = None
            if self._pending_action and "action" in self._pending_action:
                act = self._pending_action["action"]
                if isinstance(act, CommandAction):
                    pending_to_save = {"action": {"name": act.name, "args": act.args}}
                else:
                    pending_to_save = self._pending_action

            with open(self._file, "w", encoding="utf-8") as f:
                json.dump(
                    {
                        "messages": [
                            {"role": m.role, "content": m.content, "action": m.action}
                            for m in self._messages
                        ],
                        "pending_action": pending_to_save,
                    },
                    f,
                    indent=2,
                )
        except Exception as exc:
            logger.warning("Failed to save chat history: %s", exc)
