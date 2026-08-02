"""Local LLM intent parser for the Nexus desktop node.

This module provides a thin client that talks to a local OpenAI-compatible
inference server (e.g. llama.cpp's ``llama-server`` or any backend exposing
``/v1/chat/completions``).  It is **optional** — when the server is offline
or the response cannot be parsed, the parser simply returns ``None`` and
Nexus falls back to asking the human for help.
"""

from __future__ import annotations

import json
import logging
import os
import re
import urllib.error
import urllib.request
from typing import Any, Optional

from .models import CommandAction, ParsedIntent

logger = logging.getLogger(__name__)

class LocalLLMIntentParser:
    """Parse ambiguous commands using a small local LLM.

    The parser sends a compact system prompt describing the available
    CommandAction types and asks the model to reply with a JSON object like::

        {"action": "SET_VOLUME", "args": {"percent": 50}}

    If the model returns an unknown action or invalid JSON, the parser
    returns ``None`` so the caller can fall back to the human-help flow.

    Tokenization is handled by ``gigatoken`` when available. Long user prompts
    are truncated before being sent to the LLM so the context window is not
    exceeded.
    """

    # Fallback characters-per-token estimate used when gigatoken is unavailable.
    _FALLBACK_CHARS_PER_TOKEN = 4

    def __init__(
        self,
        endpoint: str = "",
        timeout: float = 3.0,
        tokenizer_model: str = "",
        max_context_size: int = 0,
        response_token_budget: int = 0,
    ):
        self.endpoint = endpoint or os.environ.get("NEXUS_LLM_ENDPOINT", "http://127.0.0.1:8080/v1/chat/completions")
        self.timeout = timeout
        # The default model is a reasonable general tokenizer. If you run a different local
        # model (e.g. Llama), set NEXUS_TOKENIZER_MODEL to a matching HuggingFace repo so
        # token counts are accurate.
        self.tokenizer_model = tokenizer_model or os.environ.get("NEXUS_TOKENIZER_MODEL", "Qwen/Qwen3-8B")
        self.max_context_size = max_context_size or int(os.environ.get("NEXUS_MAX_CONTEXT_SIZE", "4096"))
        self.response_token_budget = response_token_budget or int(os.environ.get("NEXUS_RESPONSE_TOKEN_BUDGET", "128"))
        # If the user prompt is at most this many characters, use the fast character
        # estimate instead of paying the cost to load/run gigatoken. Voice commands are
        # usually short, so this keeps the common path fast while still using exact
        # token counts for unusually long prompts.
        self.exact_token_char_threshold = int(os.environ.get("NEXUS_EXACT_TOKEN_THRESHOLD", "256"))
        self._buffer_tokens = 8
        self._tokenizer: Any = None
        self._system_prompt = self._system_prompt_text()
        self._system_token_count = 0
        self._fallback_system_token_count = len(self._system_prompt) // self._FALLBACK_CHARS_PER_TOKEN
        self._tokenizer_init_failed = False

    def _ensure_tokenizer(self) -> None:
        """Lazily initialize gigatoken and cache the system prompt token count."""
        if self._tokenizer is not None or self._tokenizer_init_failed:
            return
        try:
            import gigatoken  # type: ignore

            self._tokenizer = gigatoken.Tokenizer(self.tokenizer_model)
            encoded = self._tokenizer.encode_batch([self._system_prompt])
            self._system_token_count = len(encoded[0])
            logger.debug("Tokenizer ready (%s); system prompt uses %d tokens", self.tokenizer_model, self._system_token_count)
        except Exception as exc:
            logger.warning("Failed to initialize gigatoken tokenizer: %s", exc)
            self._tokenizer = None
            self._system_token_count = 0
            self._tokenizer_init_failed = True

    def _truncate_text(self, text: str, max_tokens: int) -> str:
        """Truncate ``text`` to fit within ``max_tokens`` tokens.

        Falls back to a character-based approximation if gigatoken is unavailable.
        """
        if not text or max_tokens <= 0:
            return text
        self._ensure_tokenizer()
        if self._tokenizer is None:
            # Rough fallback when gigatoken is unavailable.
            return text[: max(0, max_tokens * self._FALLBACK_CHARS_PER_TOKEN)]
        try:
            encoded = self._tokenizer.encode_batch([text])
            tokens = encoded[0]
            if len(tokens) <= max_tokens:
                return text
            truncated = tokens[:max_tokens]
            decoded = self._tokenizer.decode(truncated)
            if isinstance(decoded, bytes):
                decoded = decoded.decode("utf-8", errors="ignore")
            return str(decoded)
        except Exception as exc:
            logger.debug("Token truncation failed: %s", exc)
            return text[: max(0, max_tokens * self._FALLBACK_CHARS_PER_TOKEN)]

    def _prepare_user_text(self, text: str) -> str:
        """Return a possibly truncated copy of the user prompt.

        Uses a fast character-based estimate for short prompts and falls back
        to exact gigatoken counting for longer prompts.
        """
        use_exact = len(text) > self.exact_token_char_threshold
        if use_exact:
            self._ensure_tokenizer()
        system_tokens = (
            self._system_token_count
            if self._tokenizer is not None
            else self._fallback_system_token_count
        )
        available = (
            self.max_context_size
            - system_tokens
            - self.response_token_budget
            - self._buffer_tokens
        )
        if available <= 0:
            available = max(1, self.max_context_size // self._FALLBACK_CHARS_PER_TOKEN)

        if not use_exact:
            # Fast path: typical voice commands are short; avoid loading gigatoken.
            truncated = text[: max(0, available * self._FALLBACK_CHARS_PER_TOKEN)]
            if truncated != text:
                logger.debug("Truncated short user prompt from %d to %d chars", len(text), len(truncated))
            return truncated

        # Slow path: long prompt, use exact token counting.
        truncated = self._truncate_text(text, available)
        if truncated != text and len(truncated) < len(text):
            logger.debug("Truncated long user prompt from %d to %d chars", len(text), len(truncated))
        return truncated

    def parse(self, text: str) -> Optional[ParsedIntent]:
        """Ask the local LLM to turn ``text`` into a structured action.

        Returns ``None`` when the server is unavailable, the response is
        invalid, or the model admits it does not know what to do.
        """
        try:
            user_text = self._prepare_user_text(text)
            payload = {
                "messages": [
                    {"role": "system", "content": self._system_prompt},
                    {"role": "user", "content": user_text},
                ],
                "temperature": 0.1,
                "max_tokens": self.response_token_budget,
            }
            req = urllib.request.Request(
                self.endpoint,
                data=json.dumps(payload).encode("utf-8"),
                headers={"Content-Type": "application/json"},
                method="POST",
            )
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                data = json.loads(resp.read().decode("utf-8"))

            content = self._extract_content(data)
            if not content:
                return None

            return self._parse_llm_json(content, text)
        except urllib.error.URLError as exc:
            logger.debug("Local LLM unavailable: %s", exc)
            return None
        except Exception as exc:
            logger.debug("LLM parse failed: %s", exc)
            return None

    @staticmethod
    def _extract_content(data: dict) -> Optional[str]:
        choices = data.get("choices", []) if isinstance(data, dict) else []
        if not choices:
            return None
        message = choices[0].get("message", {}) if isinstance(choices[0], dict) else {}
        content = message.get("content", "")
        return str(content).strip() if content else None

    def _parse_llm_json(self, content: str, original: str) -> Optional[ParsedIntent]:
        """Parse the LLM's JSON string and validate it against known actions."""
        try:
            # Some models wrap JSON in markdown fences; strip them.
            cleaned = re.sub(r"^```(?:json)?\s*", "", content.strip(), flags=re.IGNORECASE)
            cleaned = re.sub(r"\s*```$", "", cleaned)
            data = json.loads(cleaned)
        except json.JSONDecodeError:
            return None

        if not isinstance(data, dict):
            return None

        action_name = data.get("action")
        args = data.get("args", {})
        if not isinstance(args, dict):
            args = {}

        if action_name == "UNKNOWN" or not action_name:
            return None

        try:
            action = self.build_action(action_name.upper(), args)
        except (KeyError, ValueError, TypeError) as exc:
            logger.debug("LLM returned unsupported action %s: %s", action_name, exc)
            return None

        # Confidence is lower than a rule match because the LLM could be wrong.
        return ParsedIntent(action=action, confidence=0.75, source="llm")

    @staticmethod
    def build_action(name: str, args: dict) -> CommandAction:
        """Convert the LLM's action name and args into a CommandAction.

        This is intentionally strict — if the LLM hallucinates an unsupported
        action, we reject it and ask the human.
        """
        # Helper to coerce bool values that may come back as strings/ints.
        def _bool(value) -> bool:
            return str(value).lower() in ("true", "1", "yes", "on")

        if name == "OPEN_APP":
            return CommandAction.OpenApp(str(args.get("package_name", "")))
        if name == "OPEN_WEBSITE":
            return CommandAction.OpenWebsite(str(args.get("url", "")))
        if name == "WEB_SEARCH":
            return CommandAction.WebSearch(str(args.get("query", "")))
        if name == "TOGGLE_WIFI":
            return CommandAction.ToggleWifi(_bool(args.get("enable")))
        if name == "TOGGLE_BLUETOOTH":
            return CommandAction.ToggleBluetooth(_bool(args.get("enable")))
        if name == "SET_BRIGHTNESS":
            return CommandAction.SetBrightness(int(args.get("level", 50)))
        if name == "SET_VOLUME":
            return CommandAction.SetVolume(int(args.get("percent", 50)))
        if name == "ADJUST_VOLUME":
            return CommandAction.AdjustVolume(int(args.get("delta", 0)))
        if name == "MUTE_VOLUME":
            return CommandAction.MuteVolume()
        if name == "PLAY_MEDIA":
            return CommandAction.PlayMedia(str(args.get("query", "")))
        if name == "PLAY_MEDIA_APP":
            return CommandAction.PlayMediaApp(str(args.get("query", "")), str(args.get("app_name", "")))
        if name == "PAUSE_MEDIA":
            return CommandAction.PauseMedia(str(args.get("query", "")))
        if name == "MEDIA_CONTROL":
            return CommandAction.MediaControl(str(args.get("command", "")))
        if name == "TOGGLE_FLASHLIGHT":
            return CommandAction.ToggleFlashlight(_bool(args.get("enable")))
        if name == "SET_TIMER":
            return CommandAction.SetTimer(int(args.get("seconds", 60)), str(args.get("label")) if args.get("label") else None)
        if name == "SET_ALARM":
            return CommandAction.SetAlarm(
                int(args.get("hour", 7)),
                int(args.get("minute", 0)),
                str(args.get("label")) if args.get("label") else None,
                _bool(args.get("repeating", False)),
            )
        if name == "TAKE_NOTE":
            return CommandAction.TakeNote(str(args.get("content", "")))
        if name == "ROLL_DICE":
            return CommandAction.RollDice(int(args.get("sides", 6)))
        if name == "FLIP_COIN":
            return CommandAction.FlipCoin()
        if name == "TOGGLE_DND":
            return CommandAction.ToggleDnd(_bool(args.get("enable")))
        if name == "NAVIGATE":
            return CommandAction.Navigate(str(args.get("destination", "")))
        if name == "OPEN_CALENDAR":
            return CommandAction.OpenCalendar()
        if name == "CALCULATE":
            return CommandAction.Calculate(str(args.get("expression", "")))
        if name == "SMART_HOME":
            value = args.get("value")
            return CommandAction.SmartHome(
                str(args.get("device", "")),
                str(args.get("operation", "SET_STATE")),
                str(value) if value is not None else None,
            )
        if name == "LIST_ACTION":
            return CommandAction.ListAction(args["item"], args["list_name"])
        if name == "SET_REMINDER":
            return CommandAction.SetReminder(args["task"])
        if name == "SEARCH_INFO":
            return CommandAction.SearchInfo(args["query"], args["search_type"])
        if name == "OPEN_CAMERA":
            return CommandAction.OpenCamera(args["is_selfie"])
        if name == "RECORD_VIDEO":
            return CommandAction.RecordVideo()
        if name == "CALL_CONTACT":
            return CommandAction.CallContact(args["contact"])
        if name == "SEND_TEXT":
            return CommandAction.SendText(args["contact"], args.get("message"))
        if name == "SEND_EMAIL":
            return CommandAction.SendEmail(args["recipient"])
        if name == "CANCEL_ALARM_TIMER":
            return CommandAction.CancelAlarmTimer()
        if name == "GET_TIME_DATE":
            return CommandAction.GetTimeDate()
        if name == "GET_BATTERY_STATUS":
            return CommandAction.GetBatteryStatus()
        if name == "GET_NEXT_ALARM":
            return CommandAction.GetNextAlarm()
        if name == "GET_JOKE":
            return CommandAction.GetJoke()
        if name == "GET_WEATHER":
            return CommandAction.GetWeather()
        if name == "GET_TODAY_SCHEDULE":
            return CommandAction.GetTodaySchedule()
        raise ValueError(f"Unsupported action: {name}")

    @staticmethod
    def _system_prompt_text() -> str:
        return (
            "You are the intent parser for a local voice assistant named Nexus. "
            "Map the user's request to one of the supported JSON actions below. "
            "Respond with a single JSON object only. If the request does not match "
            "any supported action, respond with {\"action\": \"UNKNOWN\"}.\n\n"
            "Supported actions (name -> args):\n"
            "  OPEN_APP: {package_name: string}\n"
            "  OPEN_WEBSITE: {url: string}\n"
            "  WEB_SEARCH: {query: string}\n"
            "  TOGGLE_WIFI: {enable: bool}\n"
            "  TOGGLE_BLUETOOTH: {enable: bool}\n"
            "  SET_BRIGHTNESS: {level: int}\n"
            "  SET_VOLUME: {percent: int}\n"
            "  ADJUST_VOLUME: {delta: int}\n"
            "  MUTE_VOLUME: {}\n"
            "  PLAY_MEDIA: {query: string}\n"
            "  PLAY_MEDIA_APP: {query: string, app_name: string}\n"
            "  PAUSE_MEDIA: {query?: string}\n"
            "  MEDIA_CONTROL: {command: string}\n"
            "  TOGGLE_FLASHLIGHT: {enable: bool}\n"
            "  SET_TIMER: {seconds: int, label?: string}\n"
            "  SET_ALARM: {hour: int, minute: int, label?: string, repeating?: bool}\n"
            "  TAKE_NOTE: {content: string}\n"
            "  ROLL_DICE: {sides?: int}\n"
            "  FLIP_COIN: {}\n"
            "  TOGGLE_DND: {enable: bool}\n"
            "  NAVIGATE: {destination: string}\n"
            "  OPEN_CALENDAR: {}\n"
            "  CALCULATE: {expression: string}\n"
            "  SMART_HOME: {device: string, operation: string, value?: string|null}\n"
            "  LIST_ACTION: {item: string, list_name: string}\n"
            "  SET_REMINDER: {task: string}\n"
            "  SEARCH_INFO: {query: string, search_type: string}\n"
            "  OPEN_CAMERA: {is_selfie: bool}\n"
            "  RECORD_VIDEO: {}\n"
            "  CALL_CONTACT: {contact: string}\n"
            "  SEND_TEXT: {contact: string, message?: string}\n"
            "  SEND_EMAIL: {recipient: string}\n"
            "  CANCEL_ALARM_TIMER: {}\n"
            "  GET_TIME_DATE: {}\n"
            "  GET_BATTERY_STATUS: {}\n"
            "  GET_NEXT_ALARM: {}\n"
            "  GET_JOKE: {}\n"
            "  GET_WEATHER: {}\n"
            "  GET_TODAY_SCHEDULE: {}\n"
        )
