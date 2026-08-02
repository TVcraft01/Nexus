# Local LLM Intent Parser
#
# Ported from existing llm_engine.py for compatibility.
# Provides optional LLM-based intent parsing for ambiguous commands.

from __future__ import annotations

import json
import logging
import urllib.request, urllib.error
from typing import Optional

from nexus_server.models import CommandAction, ParsedIntent

logger = logging.getLogger("nexus.brain.llm_engine")


class LocalLLMIntentParser:
    """Parse ambiguous commands using a local LLM."""

    def __init__(self, endpoint: str = "http://127.0.0.1:8080/v1/chat/completions"):
        self.endpoint = endpoint

    def parse(self, text: str) -> Optional[ParsedIntent]:
        try:
            payload = {
                "messages": [
                    {"role": "system", "content": self._system_prompt()},
                    {"role": "user", "content": text},
                ],
                "temperature": 0.1,
                "max_tokens": 128,
            }
            req = urllib.request.Request(
                self.endpoint,
                data=json.dumps(payload).encode("utf-8"),
                headers={"Content-Type": "application/json"},
                method="POST",
            )
            with urllib.request.urlopen(req, timeout=3.0) as resp:
                data = json.loads(resp.read().decode("utf-8"))
            choices = data.get("choices", [])
            if not choices:
                return None
            content = choices[0].get("message", {}).get("content", "")
            return self._parse_json(content, text)
        except Exception:
            return None

    def _parse_json(self, content: str, original: str) -> Optional[ParsedIntent]:
        import re
        cleaned = re.sub(r"^```(?:json)?\s*", "", content.strip(), flags=re.IGNORECASE)
        cleaned = re.sub(r"\s*```$", "", cleaned)
        try:
            data = json.loads(cleaned)
            action_name = data.get("action", "UNKNOWN")
            args = data.get("args", {})
            if action_name == "UNKNOWN":
                return None
            return ParsedIntent(
                action=CommandAction(action_name.upper(), args),
                confidence=0.75,
                source="llm",
            )
        except json.JSONDecodeError:
            return None

    @staticmethod
    def _system_prompt() -> str:
        return (
            "You are a command parser. Map user requests to JSON:\n"
            '{"action": "ACTION_NAME", "args": {...}}\n'
            "Available: OPEN_WEBSITE(url), WEB_SEARCH(query), SET_VOLUME(percent), "
            "SET_TIMER(seconds), TAKE_NOTE(content), SET_REMINDER(task), NAVIGATE(destination), "
            "GET_TIME_DATE, GET_WEATHER, GET_JOKE, CALCULATE(expression), ROLL_DICE, FLIP_COIN.\n"
            "If unsure, use {\"action\": \"UNKNOWN\"}."
        )
