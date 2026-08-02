# Nexus Brain - Conversational LLM Integration
#
# Ported from the existing brain.py. Provides natural language chat
# on top of a local LLM (Ollama, LM Studio, llama.cpp).

from __future__ import annotations

import json
import logging
import os
import re
import threading
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional
from urllib import request as urllib_request

from nexus_server.models import CommandAction, CommandResult, SAFE_COMMANDS

logger = logging.getLogger("nexus.brain")


@dataclass
class ChatMessage:
    role: str
    content: str
    action: Optional[str] = None


@dataclass
class BrainResponse:
    text: str
    action: Optional[CommandAction] = None
    action_result: Optional[CommandResult] = None
    requires_confirmation: bool = False


# System prompt (loaded from shared models/prompts)
DEFAULT_SYSTEM_PROMPT = (
    "You are Nexus, a helpful local AI assistant. Reply conversationally or run commands.\n"
    "Respond with JSON: {\"type\": \"chat\", \"content\": \"...\"} or\n"
    "{\"type\": \"command\", \"content\": \"...\", \"action\": \"ACTION_NAME\", \"args\": {...}}\n"
)


class ChatHistoryStore:
    """In-memory chat history with JSON persistence."""

    def __init__(self, storage_dir: str = ".nexus"):
        self.storage_dir = storage_dir
        os.makedirs(storage_dir, exist_ok=True)
        self._file = os.path.join(storage_dir, "chat_history.json")
        self._messages: List[ChatMessage] = []
        self._pending_action: Optional[Dict[str, Any]] = None
        self._load()

    def add(self, message: ChatMessage) -> None:
        self._messages.append(message)
        self._save()

    def recent(self, max_turns: int = 10) -> List[ChatMessage]:
        return self._messages[-max_turns * 2:]

    def queue_pending_action(self, action: CommandAction) -> None:
        self._pending_action = {"action": action}

    def pop_pending_action(self) -> Optional[Dict[str, Any]]:
        a = self._pending_action
        self._pending_action = None
        return a

    def clear(self) -> None:
        self._messages.clear()
        self._pending_action = None
        self._save()

    def _load(self) -> None:
        if not os.path.exists(self._file):
            return
        try:
            with open(self._file, "r") as f:
                data = json.load(f)
            self._messages = [ChatMessage(**m) for m in data.get("messages", [])]
        except Exception as e:
            logger.warning(f"Failed to load chat history: {e}")

    def _save(self) -> None:
        try:
            with open(self._file, "w") as f:
                json.dump({
                    "messages": [{"role": m.role, "content": m.content} for m in self._messages],
                }, f, indent=2)
        except Exception:
            pass


class NexusBrain:
    """Conversational wrapper around a local LLM and command engine."""

    MAX_CONTEXT_CHARS = 3000

    def __init__(self, command_engine, history_store=None, llm_parser=None):
        self.command_engine = command_engine
        self.history = history_store or ChatHistoryStore()
        self.llm_parser = llm_parser
        self._lock = threading.Lock()

    def chat(self, user_text: str, backend=None, auto_execute: bool = True) -> BrainResponse:
        """Process a user message through the LLM and return a response."""
        if backend is None:
            return BrainResponse(text="No local LLM server detected. Install Ollama or llama.cpp.")

        with self._lock:
            self.history.add(ChatMessage("user", user_text))

        messages = self._build_messages()
        raw = self._call_llm(backend, messages)

        if raw is None:
            return BrainResponse(text="I'm having trouble reaching the local LLM right now.")

        parsed = self._parse_json_response(raw)
        if parsed is None:
            return BrainResponse(text=raw)

        if parsed.get("type") == "command":
            return self._handle_command(parsed, backend, auto_execute)

        text = parsed.get("content", raw)
        with self._lock:
            self.history.add(ChatMessage("assistant", text))
        return BrainResponse(text=text)

    def confirm_pending_command(self, backend) -> BrainResponse:
        pending = self.history.pop_pending_action()
        if pending is None:
            return BrainResponse(text="No pending command to confirm.")
        action = pending["action"]
        result = self.command_engine.perform_action(action)
        return BrainResponse(text=result.message, action=action, action_result=result)

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

    def _call_llm(self, backend, messages: List[Dict[str, str]]) -> Optional[str]:
        try:
            payload = {
                "model": backend.selected_model or (backend.models[0] if backend.models else "local"),
                "messages": messages,
                "temperature": 0.3,
                "max_tokens": 512,
            }
            req = urllib_request.Request(
                backend.backend.chat_endpoint,
                data=json.dumps(payload).encode("utf-8"),
                headers={"Content-Type": "application/json"},
                method="POST",
            )
            with urllib_request.urlopen(req, timeout=30.0) as resp:
                data = json.loads(resp.read().decode("utf-8"))
            choices = data.get("choices", [])
            if not choices:
                return None
            message = choices[0].get("message", {})
            content = message.get("content", "")
            return str(content).strip() if content else None
        except Exception as exc:
            logger.warning(f"LLM call failed: {exc}")
            return None

    def _parse_json_response(self, content: str) -> Optional[Dict[str, Any]]:
        try:
            cleaned = re.sub(r"^```(?:json)?\s*", "", content.strip(), flags=re.IGNORECASE)
            cleaned = re.sub(r"\s*```$", "", cleaned)
            data = json.loads(cleaned)
            if isinstance(data, dict):
                return data
        except json.JSONDecodeError:
            pass
        return None

    def _handle_command(self, parsed, backend, auto_execute) -> BrainResponse:
        action_name = str(parsed.get("action", "")).upper()
        args = parsed.get("args", {}) or {}

        action = CommandAction(action_name, args)

        if not auto_execute or self._requires_confirmation(action):
            self.history.queue_pending_action(action)
            friendly = parsed.get("content", f"I'll run {action_name}. Approve?")
            return BrainResponse(text=friendly, action=action, requires_confirmation=True)

        result = self.command_engine.perform_action(action)
        return BrainResponse(text=result.message, action=action, action_result=result)

    def _requires_confirmation(self, action: CommandAction) -> bool:
        return action.name not in SAFE_COMMANDS

    @staticmethod
    def _system_prompt() -> str:
        # Try loading shared prompt from models/prompts/
        candidates = [
            os.path.join(os.path.dirname(__file__), "..", "..", "..",
                        "models", "prompts", "nexus_brain_system_prompt.md"),
            os.path.join(os.getcwd(), "models", "prompts",
                        "nexus_brain_system_prompt.md"),
        ]
        for p in candidates:
            try:
                with open(p, "r") as f:
                    return f.read()
            except (FileNotFoundError, OSError):
                continue
        return DEFAULT_SYSTEM_PROMPT
