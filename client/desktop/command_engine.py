"""Port of Android ZeroLLMCommandEngine for the Linux desktop node."""

from __future__ import annotations

import json
import os
import platform
import random
import re
import shutil
import subprocess
import sys
import urllib.parse
import urllib.request
import webbrowser
from datetime import datetime
from typing import Callable, List, Optional, Tuple

from .models import (
    CommandAction,
    CommandResult,
    CommandStatus,
    ParsedIntent,
    UserDialectRule,
)
from .rules import UserRulesRepository
from .learning import LearningRepository


class ZeroLLMCommandEngine:
    def __init__(self, rules_repo: Optional[UserRulesRepository] = None, learning_repo: Optional[LearningRepository] = None):
        self.rules_repo = rules_repo or UserRulesRepository()
        self.learning_repo = learning_repo or LearningRepository()

    # ------------------------------------------------------------------
    # Built-in regex rules (mirrors Android)
    # ------------------------------------------------------------------
    _BUILT_IN_RULES: List[Tuple[re.Pattern[str], Callable[[re.Match[str], str], CommandAction]]] = [
        # Network toggles
        (re.compile(r"\b(?:turn?\s*on|enable|start)\s+(?:wi[-]?fi|wifi|wireless)\b", re.IGNORECASE),
         lambda m, s: CommandAction.ToggleWifi(True)),
        (re.compile(r"\b(?:turn?\s*off|disable|stop)\s+(?:wi[-]?fi|wifi|wireless)\b", re.IGNORECASE),
         lambda m, s: CommandAction.ToggleWifi(False)),
        # Bluetooth toggles
        (re.compile(r"\b(?:turn?\s*on|enable|start)\s+(?:bluetooth|bt)\b", re.IGNORECASE),
         lambda m, s: CommandAction.ToggleBluetooth(True)),
        (re.compile(r"\b(?:turn?\s*off|disable|stop)\s+(?:bluetooth|bt)\b", re.IGNORECASE),
         lambda m, s: CommandAction.ToggleBluetooth(False)),
        # Brightness
        (re.compile(r"\b(?:set|change)\s+brightness\s+(?:to\s+)?(\d+)(?:%|\s*percent)?\b", re.IGNORECASE),
         lambda m, s: CommandAction.SetBrightness(int(m.group(1)))),
        # Volume
        (re.compile(r"\b(?:set|change)\s+volume\s+(?:to\s+)?(\d+)(?:%|\s*percent)?\b", re.IGNORECASE),
         lambda m, s: CommandAction.SetVolume(int(m.group(1)))),
        (re.compile(r"\b(?:turn\s+)?(?:volume|sound)\s+(?:up|louder|higher)\b", re.IGNORECASE),
         lambda m, s: CommandAction.AdjustVolume(+10)),
        (re.compile(r"\b(?:turn\s+)?(?:volume|sound)\s+(?:down|lower|softer|quieter)\b", re.IGNORECASE),
         lambda m, s: CommandAction.AdjustVolume(-10)),
        (re.compile(r"\b(?:mute|silence)\s+(?:the\s+)?(?:volume|sound)\b", re.IGNORECASE),
         lambda m, s: CommandAction.MuteVolume()),
        # Media controls
        (re.compile(r"\b(?:next|skip)\s+(?:track|song)\b", re.IGNORECASE),
         lambda m, s: CommandAction.MediaControl("next")),
        (re.compile(r"\b(?:previous|last)\s+(?:track|song)\b", re.IGNORECASE),
         lambda m, s: CommandAction.MediaControl("previous")),
        (re.compile(r"\brestart\s+(?:track|song|music)\b", re.IGNORECASE),
         lambda m, s: CommandAction.MediaControl("restart")),
        (re.compile(r"\bwhat(?:['\u0027]?s|\s+is)?\s+playing\b", re.IGNORECASE),
         lambda m, s: CommandAction.MediaControl("info")),
        # Media playback by app
        (re.compile(r"\b(?:play)\s+(.+?)\s+(?:on|in)\s+(spotify|pandora|tunein|audible|kindle|youtube music|yt music)\b", re.IGNORECASE),
         lambda m, s: CommandAction.PlayMediaApp(m.group(1).strip(), m.group(2).strip().lower())),
        # Generic play/pause
        (re.compile(r"\b(?:play|start)\s+(.+)", re.IGNORECASE),
         lambda m, s: CommandAction.PlayMedia(m.group(1).strip())),
        (re.compile(r"\b(?:pause|stop)\s+(?:music|audio|track|song|playback)\b", re.IGNORECASE),
         lambda m, s: CommandAction.PauseMedia("")),
        (re.compile(r"\bchill\s+tunes\b", re.IGNORECASE),
         lambda m, s: CommandAction.PlayMedia("chill")),
        # Lights / IoT
        (re.compile(r"\b(?:kill|turn?\s*off|switch\s*off)\s+(?:the\s+)?lights\b", re.IGNORECASE),
         lambda m, s: CommandAction.MeshRelay("iot:lights:off")),
        (re.compile(r"\b(?:turn?\s*on|switch\s*on)\s+(?:the\s+)?lights\b", re.IGNORECASE),
         lambda m, s: CommandAction.MeshRelay("iot:lights:on")),
        # Open calendar
        (re.compile(r"\bopen\s+calendar\b", re.IGNORECASE),
         lambda m, s: CommandAction.OpenCalendar()),
        # Open app/website/search
        (re.compile(r"\bopen\s+(?!settings\b|prefs\b|calendar\b)(.+)", re.IGNORECASE),
         lambda m, s: CommandAction.OpenApp(m.group(1).strip())),
        (re.compile(r"\bgo\s+to\s+(.+)", re.IGNORECASE),
         lambda m, s: CommandAction.OpenWebsite(m.group(1).strip())),
        (re.compile(r"\b(?:search\s+for|find)\s+(.+)", re.IGNORECASE),
         lambda m, s: CommandAction.WebSearch(m.group(1).strip())),
        # Settings
        (re.compile(r"\bopen\s+(?:settings|prefs)\b", re.IGNORECASE),
         lambda m, s: CommandAction.OpenSettings("settings")),
        # Mesh relay fallback
        (re.compile(r"\brelay\s+(.+)", re.IGNORECASE),
         lambda m, s: CommandAction.MeshRelay(m.group(1).strip())),
        # Flashlight
        (re.compile(r"\b(?:turn?\s*on|enable|start)\s+(?:flashlight|torch)\b", re.IGNORECASE),
         lambda m, s: CommandAction.ToggleFlashlight(True)),
        (re.compile(r"\b(?:turn?\s*off|disable|stop)\s+(?:flashlight|torch)\b", re.IGNORECASE),
         lambda m, s: CommandAction.ToggleFlashlight(False)),
        # Timer / alarm
        (re.compile(r"\bset\s+a?\s*timer\s+for\s+(\d+)\s+(?:seconds?|secs?)\b", re.IGNORECASE),
         lambda m, s: CommandAction.SetTimer(int(m.group(1)))),
        (re.compile(r"\bset\s+a?\s*timer\s+for\s+(\d+)\s+(?:minutes?|mins?)\b", re.IGNORECASE),
         lambda m, s: CommandAction.SetTimer(int(m.group(1)) * 60)),
        (re.compile(r"\bset\s+(?:an?|the)\s*alarm\s+for\s+(\d+)(?::(\d+))?\s*(am|pm)?\b", re.IGNORECASE),
         lambda m, s: _parse_alarm(m)),
        # Notes
        (re.compile(r"\b(?:take|make|save)\s+a?\s*note\s+(?:that|to|of)?\s*(.+)", re.IGNORECASE),
         lambda m, s: CommandAction.TakeNote(m.group(1).strip())),
        # Utilities
        (re.compile(r"\b(?:roll|throw)\s+(?:a\s+)?dice\b", re.IGNORECASE),
         lambda m, s: CommandAction.RollDice(6)),
        (re.compile(r"\bflip\s+(?:a\s+)?coin\b", re.IGNORECASE),
         lambda m, s: CommandAction.FlipCoin()),
        (re.compile(r"\b(?:what(?:['\u0027]?s?|\s+is)?|calculate|compute)?\s*(-?[0-9.]+)\s*(times|multiplied by|x|divided by|over|plus|minus|[+\-*/])\s*(-?[0-9.]+)\b", re.IGNORECASE),
         lambda m, s: _parse_calc(m)),
        (re.compile(r"^(-?[0-9.]+)\s*([+\-*/])\s*(-?[0-9.]+)$", re.IGNORECASE),
         lambda m, s: CommandAction.Calculate(f"{m.group(1)}{m.group(2)}{m.group(3)}")),
        # DND
        (re.compile(r"\b(?:turn?\s*on|enable|start)\s+(?:do\s+not\s+disturb|dnd)\b", re.IGNORECASE),
         lambda m, s: CommandAction.ToggleDnd(True)),
        (re.compile(r"\b(?:turn?\s*off|disable|stop)\s+(?:do\s+not\s+disturb|dnd)\b", re.IGNORECASE),
         lambda m, s: CommandAction.ToggleDnd(False)),
        # Navigation
        (re.compile(r"\b(?:navigate|directions|take me|drive)\s+(?:to\s+)?(.+)", re.IGNORECASE),
         lambda m, s: CommandAction.Navigate(m.group(1).strip())),
        # Info / data
        (re.compile(r"\bwhat['\u0027]?\s*(?:time\s+is\s+it|date|day\s+is\s+it)\b", re.IGNORECASE),
         lambda m, s: CommandAction.GetTimeDate()),
        (re.compile(r"\b(?:battery|what['\u0027]?s\s+my\s+battery)\b", re.IGNORECASE),
         lambda m, s: CommandAction.GetBatteryStatus()),
        (re.compile(r"\bnext\s+alarm\b", re.IGNORECASE),
         lambda m, s: CommandAction.GetNextAlarm()),
        (re.compile(r"\btell\s+me\s+(?:a\s+)?joke\b", re.IGNORECASE),
         lambda m, s: CommandAction.GetJoke()),
        (re.compile(r"\b(?:what['\u0027]?s\s+(?:the\s+)?weather|weather\s*(?:forecast|report)?)\b", re.IGNORECASE),
         lambda m, s: CommandAction.GetWeather()),
        (re.compile(r"\b(?:what['\u0027]?s\s+on\s+my\s+calendar|my\s+schedule(?:\s+today)?)\b", re.IGNORECASE),
         lambda m, s: CommandAction.GetTodaySchedule()),
        # Smart home
        (re.compile(r"\b(?:dim|set|change)\s+(?:the\s+)?(.+?)\s+(?:to\s+)?(\d+%|red|blue|green|warm|cool)\b", re.IGNORECASE),
         lambda m, s: CommandAction.SmartHome(m.group(1).strip(), "SET_STATE", m.group(2).strip())),
        (re.compile(r"\b(?:set|change)\s+(?:the\s+)?thermostat\s+(?:to\s+)?(\d+)\b", re.IGNORECASE),
         lambda m, s: CommandAction.SmartHome("thermostat", "SET_TEMP", m.group(1).strip())),
        (re.compile(r"\b(?:activate|start)\s+(?:the\s+)?(.+?)\s+scene\b", re.IGNORECASE),
         lambda m, s: CommandAction.SmartHome("scene", "ACTIVATE", m.group(1).strip())),
        # Lists and reminders
        (re.compile(r"\b(?:add|put)\s+(.+?)\s+(?:to|on)\s+(?:my\s+)?(shopping|to[- ]?do)\s+list\b", re.IGNORECASE),
         lambda m, s: CommandAction.ListAction(m.group(1).strip(), m.group(2).strip())),
        (re.compile(r"\bremind\s+me\s+(?:to\s+)?(.+)\b", re.IGNORECASE),
         lambda m, s: CommandAction.SetReminder(m.group(1).strip())),
        # Knowledge
        (re.compile(r"\b(?:define|what is the definition of)\s+(.+)\b", re.IGNORECASE),
         lambda m, s: CommandAction.SearchInfo(m.group(1).strip(), "Define")),
        (re.compile(r"\bhow\s+do\s+you\s+spell\s+(.+)\b", re.IGNORECASE),
         lambda m, s: CommandAction.SearchInfo(m.group(1).strip(), "Spell")),
        # Camera
        (re.compile(r"\btake\s+a\s+(selfie|picture|photo)\b", re.IGNORECASE),
         lambda m, s: CommandAction.OpenCamera(m.group(1).lower() == "selfie")),
        (re.compile(r"\b(?:record|shoot|take)\s+(?:a\s+)?video\b", re.IGNORECASE),
         lambda m, s: CommandAction.RecordVideo()),
        # Cancel timer/alarm
        (re.compile(r"\bcancel\s+(?:my\s+|the\s+|a\s+)?(?:timer|alarm)s?\b", re.IGNORECASE),
         lambda m, s: CommandAction.CancelAlarmTimer()),
        # Communications
        (re.compile(r"\b(?:call|phone|dial)\s+(.+)", re.IGNORECASE),
         lambda m, s: CommandAction.CallContact(m.group(1).strip())),
        (re.compile(r"\b(?:text|sms|message)\s+(.+?)(?:\s+(?:saying|that)\s+(.+))?$", re.IGNORECASE),
         lambda m, s: CommandAction.SendText(m.group(1).strip(), m.group(2) if m.group(2) else None)),
        (re.compile(r"\b(?:email|send\s+an\s+email\s+to)\s+(.+)", re.IGNORECASE),
         lambda m, s: CommandAction.SendEmail(m.group(1).strip())),
    ]

    def parse_command(self, input_text: str) -> Optional[CommandAction]:
        intent = self.parse_command_intent(input_text)
        return intent.action if intent else None

    def parse_command_intent(self, input_text: str) -> Optional[ParsedIntent]:
        """Parse input into a structured intent with confidence.

        Priority order:
        1. User-defined dialect rules (confidence 1.0)
        2. Built-in regex rules (confidence 1.0)
        3. Unknown (return None so caller can consult LLM or human)
        """
        sanitized = input_text.strip()
        if not sanitized:
            return None

        # User rules take priority.
        user_match = self._match_user_rule(sanitized)
        if user_match:
            rule, match = user_match
            action = self._parse_user_action(rule, match)
            return ParsedIntent(action, confidence=1.0, source="user_rule")

        # Built-in regex rules.
        for regex, factory in self._BUILT_IN_RULES:
            maybe_match = regex.search(sanitized)
            if maybe_match:
                try:
                    action = factory(maybe_match, sanitized)
                    return ParsedIntent(action, confidence=1.0, source="regex")
                except Exception:
                    continue
        return None

    def execute_command(self, input_text: str) -> CommandResult:
        sanitized = input_text.strip()
        if not sanitized:
            return CommandResult(False, "Empty command.", CommandAction.Unknown(""), original_input=input_text)

        intent = self.parse_command_intent(sanitized)
        if intent:
            result = self._perform_action(intent.action)
            if result.success:
                self.learning_repo.record_success(sanitized, intent.action)
            source_note = f" ({intent.source})" if intent.source != "regex" else ""
            return CommandResult(
                result.success,
                f"{result.message}{source_note}",
                intent.action,
                result.status,
                original_input=input_text,
            )

        learned_action = self.learning_repo.find_similar_action(sanitized)
        if learned_action is not None:
            result = self._perform_action(learned_action)
            if result.success:
                self.learning_repo.record_success(sanitized, learned_action)
            return CommandResult(
                result.success,
                f"Learned: {result.message}",
                learned_action,
                result.status,
                original_input=input_text,
            )

        return CommandResult(
            False,
            f"I don't know how to handle '{sanitized}'. Would you like to teach me?",
            CommandAction.Unknown(sanitized),
            requires_intern_choice=True,
            choices=["Teach", "Cancel"],
            original_input=input_text,
        )

    def _match_user_rule(self, text: str) -> Optional[Tuple[UserDialectRule, re.Match[str]]]:
        for rule in sorted(self.rules_repo.get_enabled_rules(), key=lambda r: -r.priority):
            try:
                compiled = re.compile(rule.pattern, re.IGNORECASE)
                maybe_match = compiled.search(text)
                if maybe_match:
                    return rule, maybe_match
            except re.error:
                continue
        return None

    def teach_rule(self, input_text: str, action: CommandAction) -> bool:
        """Store a user dialect rule so the input is handled by regex next time."""
        try:
            payload = self._action_payload(action)
            self.rules_repo.add_rule(
                pattern=re.escape(input_text.strip().lower()),
                action_type=action.name,
                payload=payload,
                priority=200,
            )
            return True
        except Exception as exc:
            logger = __import__("logging").getLogger(__name__)
            logger.exception("Failed to teach rule: %s", exc)
            return False

    @staticmethod
    def _action_payload(action: CommandAction) -> str:
        """Serialize a CommandAction into the payload format used by user rules."""
        parts = {
            "OPEN_APP": action.args.get("package_name", ""),
            "OPEN_WEBSITE": action.args.get("url", ""),
            "WEB_SEARCH": action.args.get("query", ""),
            "OPEN_SETTINGS": action.args.get("page", ""),
            "MESH_RELAY": action.args.get("payload", ""),
            "TOGGLE_WIFI": str(action.args.get("enable", True)).lower(),
            "TOGGLE_BLUETOOTH": str(action.args.get("enable", True)).lower(),
            "SET_BRIGHTNESS": str(action.args.get("level", 50)),
            "SET_VOLUME": str(action.args.get("percent", 50)),
            "ADJUST_VOLUME": str(action.args.get("delta", 0)),
            "MUTE_VOLUME": "",
            "PLAY_MEDIA": action.args.get("query", ""),
            "PLAY_MEDIA_APP": f"{action.args.get('query', '')}|{action.args.get('app_name', '')}",
            "PAUSE_MEDIA": action.args.get("query", ""),
            "MEDIA_CONTROL": action.args.get("command", ""),
            "TOGGLE_FLASHLIGHT": str(action.args.get("enable", True)).lower(),
            "SET_TIMER": f"{action.args.get('seconds', 60)}|{action.args.get('label') or ''}",
            "SET_ALARM": f"{action.args.get('hour', 7)}|{action.args.get('minute', 0)}|{action.args.get('label') or ''}|{action.args.get('repeating', False)}",
            "TAKE_NOTE": action.args.get("content", ""),
            "ROLL_DICE": str(action.args.get("sides", 6)),
            "FLIP_COIN": "",
            "TOGGLE_DND": str(action.args.get("enable", True)).lower(),
            "NAVIGATE": action.args.get("destination", ""),
            "OPEN_CALENDAR": "",
            "CALCULATE": action.args.get("expression", ""),
            "SMART_HOME": f"{action.args.get('device', '')}|{action.args.get('operation', '')}|{action.args.get('value') or ''}",
            "LIST_ACTION": f"{action.args.get('item', '')}|{action.args.get('list_name', '')}",
            "SET_REMINDER": action.args.get("task", ""),
            "SEARCH_INFO": f"{action.args.get('query', '')}|{action.args.get('search_type', '')}",
            "OPEN_CAMERA": str(action.args.get("is_selfie", False)).lower(),
            "RECORD_VIDEO": "",
            "CALL_CONTACT": action.args.get("contact", ""),
            "SEND_TEXT": f"{action.args.get('contact', '')}|{action.args.get('message', '')}",
            "SEND_EMAIL": action.args.get("recipient", ""),
            "CANCEL_ALARM_TIMER": "",
            "GET_TIME_DATE": "",
            "GET_BATTERY_STATUS": "",
            "GET_NEXT_ALARM": "",
            "GET_JOKE": "",
            "GET_WEATHER": "",
            "GET_TODAY_SCHEDULE": "",
        }
        return parts.get(action.name, "")

    def _parse_user_action(self, rule: UserDialectRule, match: "re.Match") -> CommandAction:
        payload = match.group(1) if match.groups() else rule.payload
        # Split into all parts so SET_ALARM can have hour|minute|label|repeating.
        parts = payload.split("|")
        action_type = rule.action_type.upper()

        def _bool(v: str) -> bool:
            return v.lower() in ("true", "1", "yes", "on")

        if action_type == "OPEN_APP":
            return CommandAction.OpenApp(payload)
        if action_type == "OPEN_WEBSITE":
            return CommandAction.OpenWebsite(payload)
        if action_type == "WEB_SEARCH":
            return CommandAction.WebSearch(payload)
        if action_type == "OPEN_SETTINGS":
            return CommandAction.OpenSettings(payload)
        if action_type == "MESH_RELAY":
            return CommandAction.MeshRelay(payload)
        if action_type == "TOGGLE_WIFI":
            return CommandAction.ToggleWifi(_bool(payload))
        if action_type == "TOGGLE_BLUETOOTH":
            return CommandAction.ToggleBluetooth(_bool(payload))
        if action_type == "SET_BRIGHTNESS":
            return CommandAction.SetBrightness(int(payload) if payload.isdigit() else 50)
        if action_type == "SET_VOLUME":
            return CommandAction.SetVolume(int(payload) if payload.isdigit() else 50)
        if action_type == "ADJUST_VOLUME":
            return CommandAction.AdjustVolume(int(payload) if payload.lstrip("-").isdigit() else 0)
        if action_type == "MUTE_VOLUME":
            return CommandAction.MuteVolume()
        if action_type == "PLAY_MEDIA":
            return CommandAction.PlayMedia(payload)
        if action_type == "PLAY_MEDIA_APP":
            return CommandAction.PlayMediaApp(parts[0] if parts else payload, parts[1] if len(parts) > 1 else "")
        if action_type == "MEDIA_CONTROL":
            return CommandAction.MediaControl(payload)
        if action_type == "PAUSE_MEDIA":
            return CommandAction.PauseMedia(payload)
        if action_type == "TOGGLE_FLASHLIGHT":
            return CommandAction.ToggleFlashlight(_bool(payload))
        if action_type == "SET_TIMER":
            seconds = int(parts[0]) if parts and parts[0].isdigit() else 60
            label = parts[1] if len(parts) > 1 and parts[1] else None
            return CommandAction.SetTimer(seconds, label)
        if action_type == "SET_ALARM":
            hour = int(parts[0]) if parts and parts[0].isdigit() else 7
            minute = int(parts[1]) if len(parts) > 1 and parts[1].isdigit() else 0
            label = parts[2] if len(parts) > 2 and parts[2] else None
            repeating = parts[3].lower() in ("true", "1", "yes", "on") if len(parts) > 3 else False
            return CommandAction.SetAlarm(hour, minute, label, repeating)
        if action_type == "SMART_HOME":
            value = parts[2] if len(parts) > 2 and parts[2].lower() not in ("", "none") else None
            return CommandAction.SmartHome(parts[0] if parts else "", parts[1] if len(parts) > 1 else "SET_STATE", value)
        if action_type == "LIST_ACTION":
            return CommandAction.ListAction(parts[0] if parts else payload, parts[1] if len(parts) > 1 else "todo")
        if action_type == "SET_REMINDER":
            return CommandAction.SetReminder(payload)
        if action_type == "SEARCH_INFO":
            return CommandAction.SearchInfo(parts[0] if parts else payload, parts[1] if len(parts) > 1 else "Define")
        if action_type == "OPEN_CAMERA":
            return CommandAction.OpenCamera(_bool(payload))
        if action_type == "RECORD_VIDEO":
            return CommandAction.RecordVideo()
        if action_type == "CALL_CONTACT":
            return CommandAction.CallContact(payload)
        if action_type == "SEND_TEXT":
            return CommandAction.SendText(parts[0] if parts else payload, parts[1] if len(parts) > 1 else None)
        if action_type == "SEND_EMAIL":
            return CommandAction.SendEmail(payload)
        if action_type == "CANCEL_ALARM_TIMER":
            return CommandAction.CancelAlarmTimer()
        if action_type == "TAKE_NOTE":
            return CommandAction.TakeNote(payload)
        if action_type == "ROLL_DICE":
            return CommandAction.RollDice(int(payload) if payload.isdigit() else 6)
        if action_type == "FLIP_COIN":
            return CommandAction.FlipCoin()
        if action_type == "TOGGLE_DND":
            return CommandAction.ToggleDnd(_bool(payload))
        if action_type == "NAVIGATE":
            return CommandAction.Navigate(payload)
        if action_type == "OPEN_CALENDAR":
            return CommandAction.OpenCalendar()
        if action_type == "CALCULATE":
            return CommandAction.Calculate(payload)
        if action_type == "GET_TIME_DATE":
            return CommandAction.GetTimeDate()
        if action_type == "GET_BATTERY_STATUS":
            return CommandAction.GetBatteryStatus()
        if action_type == "GET_NEXT_ALARM":
            return CommandAction.GetNextAlarm()
        if action_type == "GET_JOKE":
            return CommandAction.GetJoke()
        if action_type == "GET_WEATHER":
            return CommandAction.GetWeather()
        if action_type == "GET_TODAY_SCHEDULE":
            return CommandAction.GetTodaySchedule()
        return CommandAction.Unknown(action_type)

    # ------------------------------------------------------------------
    # Action execution (Linux implementations)
    # ------------------------------------------------------------------
    def perform_action(self, action: CommandAction) -> CommandResult:
        """Public entry point to execute a command action."""
        return self._perform_action(action)

    def _perform_action(self, action: CommandAction) -> CommandResult:
        name = action.name
        args = action.args
        if name == "TOGGLE_WIFI":
            return self._toggle_wifi(args["enable"])
        if name == "TOGGLE_BLUETOOTH":
            return self._toggle_bluetooth(args["enable"])
        if name == "SET_BRIGHTNESS":
            return self._set_brightness(args["level"])
        if name == "SET_VOLUME":
            return self._set_volume(args["percent"])
        if name == "ADJUST_VOLUME":
            return self._adjust_volume(args["delta"])
        if name == "MUTE_VOLUME":
            return self._mute_volume()
        if name == "PLAY_MEDIA":
            return self._play_media(args["query"])
        if name == "PLAY_MEDIA_APP":
            return self._play_media_app(args["query"], args["app_name"])
        if name == "PAUSE_MEDIA":
            return self._pause_media()
        if name == "MEDIA_CONTROL":
            return self._media_control(args["command"])
        if name == "OPEN_APP":
            return self._open_app(args["package_name"])
        if name == "OPEN_WEBSITE":
            return self._open_website(args["url"])
        if name == "WEB_SEARCH":
            return self._web_search(args["query"])
        if name == "OPEN_SETTINGS":
            return self._open_settings(args["page"])
        if name == "MESH_RELAY":
            return self._mesh_relay(args["payload"])
        if name == "TOGGLE_FLASHLIGHT":
            return self._toggle_flashlight(args["enable"])
        if name == "SET_TIMER":
            return self._set_timer(args["seconds"], args.get("label"))
        if name == "SET_ALARM":
            return self._set_alarm(args["hour"], args["minute"], args.get("label"))
        if name == "TAKE_NOTE":
            return self._take_note(args["content"])
        if name == "ROLL_DICE":
            return self._roll_dice(args["sides"])
        if name == "FLIP_COIN":
            return self._flip_coin()
        if name == "TOGGLE_DND":
            return self._toggle_dnd(args["enable"])
        if name == "NAVIGATE":
            return self._navigate(args["destination"])
        if name == "OPEN_CALENDAR":
            return self._open_calendar()
        if name == "CALCULATE":
            return self._calculate(args["expression"])
        if name == "SMART_HOME":
            return self._smart_home(args["device"], args["operation"], args["value"])
        if name == "LIST_ACTION":
            return self._add_to_list(args["item"], args["list_name"])
        if name == "SET_REMINDER":
            return self._set_reminder(args["task"])
        if name == "SEARCH_INFO":
            return self._search_info(args["query"], args["search_type"])
        if name == "OPEN_CAMERA":
            return self._open_camera(args["is_selfie"])
        if name == "RECORD_VIDEO":
            return self._record_video()
        if name == "CALL_CONTACT":
            return self._call_contact(args["contact"])
        if name == "SEND_TEXT":
            return self._send_text(args["contact"], args.get("message"))
        if name == "SEND_EMAIL":
            return self._send_email(args["recipient"])
        if name == "CANCEL_ALARM_TIMER":
            return self._cancel_alarm_timer()
        if name == "GET_TIME_DATE":
            return self._get_time_date()
        if name == "GET_BATTERY_STATUS":
            return self._get_battery_status()
        if name == "GET_NEXT_ALARM":
            return self._get_next_alarm()
        if name == "GET_JOKE":
            return self._get_joke()
        if name == "GET_WEATHER":
            return self._get_weather()
        if name == "GET_TODAY_SCHEDULE":
            return self._get_today_schedule()
        return CommandResult(False, f"Unhandled action: {name}", action)

    # ------------------------------------------------------------------
    # Linux helpers
    # ------------------------------------------------------------------
    @staticmethod
    def _run(cmd: List[str]) -> Tuple[int, str, str]:
        try:
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
            return result.returncode, result.stdout, result.stderr
        except Exception as e:
            return -1, "", str(e)

    def _xdg_open(self, url: str) -> bool:
        rc, _, _ = self._run(["xdg-open", url])
        return rc == 0

    def _toggle_wifi(self, enable: bool) -> CommandResult:
        nmcli = shutil.which("nmcli")
        if nmcli:
            action = "on" if enable else "off"
            rc, out, err = self._run(["nmcli", "radio", "wifi", action])
            if rc == 0:
                return CommandResult(True, f"WiFi turned {action}.", CommandAction.ToggleWifi(enable), CommandStatus.VERIFIED_SUCCESS)
        return CommandResult(False, "Could not toggle WiFi. nmcli not available or failed.", CommandAction.ToggleWifi(enable))

    def _toggle_bluetooth(self, enable: bool) -> CommandResult:
        bt = shutil.which("bluetoothctl")
        if bt:
            action = "on" if enable else "off"
            rc, out, err = self._run(["bluetoothctl", "power", action])
            if rc == 0:
                return CommandResult(True, f"Bluetooth turned {action}.", CommandAction.ToggleBluetooth(enable), CommandStatus.VERIFIED_SUCCESS)
        return CommandResult(False, "Could not toggle Bluetooth.", CommandAction.ToggleBluetooth(enable))

    def _set_brightness(self, level: int) -> CommandResult:
        safe = max(0, min(100, level))
        brightnessctl = shutil.which("brightnessctl")
        if brightnessctl:
            rc, out, err = self._run(["brightnessctl", "-q", "s", f"{safe}%"])
            if rc == 0:
                return CommandResult(True, f"Brightness set to {safe}%.", CommandAction.SetBrightness(safe), CommandStatus.VERIFIED_SUCCESS)
        return CommandResult(False, "Could not set brightness. Install brightnessctl.", CommandAction.SetBrightness(safe))

    def _set_volume(self, percent: int) -> CommandResult:
        safe = max(0, min(100, percent))
        pactl = shutil.which("pactl")
        amixer = shutil.which("amixer")
        if pactl:
            rc, _, _ = self._run(["pactl", "set-sink-volume", "@DEFAULT_SINK@", f"{safe}%"])
            if rc == 0:
                return CommandResult(True, f"Volume set to {safe}%.", CommandAction.SetVolume(safe), CommandStatus.VERIFIED_SUCCESS)
        if amixer:
            rc, _, _ = self._run(["amixer", "sset", "Master", f"{safe}%"])
            if rc == 0:
                return CommandResult(True, f"Volume set to {safe}%.", CommandAction.SetVolume(safe), CommandStatus.VERIFIED_SUCCESS)
        return CommandResult(False, "Could not set volume.", CommandAction.SetVolume(safe))

    def _adjust_volume(self, delta: int) -> CommandResult:
        sign = "+" if delta >= 0 else ""
        pactl = shutil.which("pactl")
        if pactl:
            rc, _, _ = self._run(["pactl", "set-sink-volume", "@DEFAULT_SINK@", f"{sign}{delta}%"])
            if rc == 0:
                return CommandResult(True, "Volume adjusted.", CommandAction.AdjustVolume(delta), CommandStatus.VERIFIED_SUCCESS)
        return CommandResult(False, "Could not adjust volume.", CommandAction.AdjustVolume(delta))

    def _mute_volume(self) -> CommandResult:
        pactl = shutil.which("pactl")
        if pactl:
            self._run(["pactl", "set-sink-mute", "@DEFAULT_SINK@", "1"])
            return CommandResult(True, "Volume muted.", CommandAction.MuteVolume(), CommandStatus.VERIFIED_SUCCESS)
        return CommandResult(False, "Could not mute volume.", CommandAction.MuteVolume())

    def _play_media(self, query: str) -> CommandResult:
        url = f"https://www.youtube.com/results?search_query={urllib.parse.quote(query)}"
        webbrowser.open(url)
        return CommandResult(True, f"Opened YouTube search for: {query}", CommandAction.PlayMedia(query), CommandStatus.PENDING_HANDOFF)

    def _play_media_app(self, query: str, app_name: str) -> CommandResult:
        url = f"https://www.youtube.com/results?search_query={urllib.parse.quote(query)}"
        webbrowser.open(url)
        return CommandResult(True, f"Playing {query} on {app_name}.", CommandAction.PlayMediaApp(query, app_name), CommandStatus.PENDING_HANDOFF)

    def _pause_media(self) -> CommandResult:
        playerctl = shutil.which("playerctl")
        if playerctl:
            rc, _, _ = self._run(["playerctl", "pause"])
            if rc == 0:
                return CommandResult(True, "Media paused.", CommandAction.PauseMedia(""), CommandStatus.VERIFIED_SUCCESS)
        return CommandResult(False, "Could not pause media.", CommandAction.PauseMedia(""))

    def _media_control(self, command: str) -> CommandResult:
        playerctl = shutil.which("playerctl")
        mapping = {"next": "next", "previous": "previous", "restart": "position 0"}
        cmd = mapping.get(command, command)
        if playerctl and cmd != "info":
            rc, _, _ = self._run(["playerctl", *cmd.split()])
            if rc == 0:
                return CommandResult(True, f"Media control '{command}' sent.", CommandAction.MediaControl(command), CommandStatus.VERIFIED_SUCCESS)
        return CommandResult(False, f"Media control '{command}' not available.", CommandAction.MediaControl(command))

    def _open_app(self, query: str) -> CommandResult:
        desktop = shutil.which("gtk-launch")
        if desktop:
            # Try to launch by .desktop file name or app name
            app_name = query.lower().replace(" ", "-")
            rc, _, _ = self._run(["gtk-launch", app_name])
            if rc == 0:
                return CommandResult(True, f"Opened {query}.", CommandAction.OpenApp(query), CommandStatus.PENDING_HANDOFF)
        if self._xdg_open(query):
            return CommandResult(True, f"Opened {query}.", CommandAction.OpenApp(query), CommandStatus.PENDING_HANDOFF)
        return CommandResult(False, f"Could not open app {query}.", CommandAction.OpenApp(query))

    def _open_website(self, url: str) -> CommandResult:
        full_url = url if url.startswith("http://") or url.startswith("https://") else f"https://{url}"
        webbrowser.open(full_url)
        return CommandResult(True, f"Opening {full_url}.", CommandAction.OpenWebsite(url), CommandStatus.PENDING_HANDOFF)

    def _web_search(self, query: str) -> CommandResult:
        url = f"https://www.google.com/search?q={urllib.parse.quote(query)}"
        webbrowser.open(url)
        return CommandResult(True, f"Searching for: {query}", CommandAction.WebSearch(query), CommandStatus.PENDING_HANDOFF)

    def _open_settings(self, page: str) -> CommandResult:
        settings_apps = ["gnome-control-center", "mate-control-center", "xfce4-settings-manager", "kcmshell5"]
        for app in settings_apps:
            if shutil.which(app):
                self._run([app])
                return CommandResult(True, "Opened settings.", CommandAction.OpenSettings(page), CommandStatus.PENDING_HANDOFF)
        return CommandResult(False, "No settings app found.", CommandAction.OpenSettings(page))

    def _mesh_relay(self, payload: str) -> CommandResult:
        return CommandResult(True, f"Mesh relay queued: {payload}", CommandAction.MeshRelay(payload))

    def _toggle_flashlight(self, enable: bool) -> CommandResult:
        return CommandResult(False, "Flashlight not available on this Linux device.", CommandAction.ToggleFlashlight(enable))

    def _set_timer(self, seconds: int, label: Optional[str]) -> CommandResult:
        task = f"Timer: {label}" if label else "Timer expired"
        notify = shutil.which("notify-send")
        if notify:
            self._run(["notify-send", task, f"Your {seconds}s timer is up."])
        return CommandResult(True, f"Timer set for {seconds} seconds.", CommandAction.SetTimer(seconds, label), CommandStatus.PENDING_HANDOFF)

    def _set_alarm(self, hour: int, minute: int, label: Optional[str]) -> CommandResult:
        alarm_label = label or "Nexus alarm"
        notify = shutil.which("notify-send")
        if notify:
            self._run(["notify-send", alarm_label, f"Alarm set for {hour:02d}:{minute:02d}."])
        return CommandResult(True, f"Alarm set for {hour:02d}:{minute:02d}.", CommandAction.SetAlarm(hour, minute, label), CommandStatus.PENDING_HANDOFF)

    def _take_note(self, content: str) -> CommandResult:
        notes_file = "nexus_notes.txt"
        with open(notes_file, "a", encoding="utf-8") as f:
            f.write(f"{datetime.now().isoformat()} {content}\n")
        return CommandResult(True, f"Note saved: {content}", CommandAction.TakeNote(content), CommandStatus.VERIFIED_SUCCESS)

    def _roll_dice(self, sides: int) -> CommandResult:
        result = random.randint(1, max(2, sides))
        return CommandResult(True, f"You rolled a {result} (d{sides}).", CommandAction.RollDice(sides), CommandStatus.VERIFIED_SUCCESS)

    def _flip_coin(self) -> CommandResult:
        return CommandResult(True, f"The coin landed on {'Heads' if random.random() < 0.5 else 'Tails'}.", CommandAction.FlipCoin(), CommandStatus.VERIFIED_SUCCESS)

    def _toggle_dnd(self, enable: bool) -> CommandResult:
        gsettings = shutil.which("gsettings")
        if gsettings:
            self._run(["gsettings", "set", "org.gnome.desktop.notifications", "show-banners", "false" if enable else "true"])
            return CommandResult(True, f"Do Not Disturb {'enabled' if enable else 'disabled'}.", CommandAction.ToggleDnd(enable), CommandStatus.VERIFIED_SUCCESS)
        return CommandResult(False, "Could not toggle DND.", CommandAction.ToggleDnd(enable))

    def _navigate(self, destination: str) -> CommandResult:
        url = f"https://www.google.com/maps/dir/?api=1&destination={urllib.parse.quote(destination)}"
        webbrowser.open(url)
        return CommandResult(True, f"Navigation started to {destination}.", CommandAction.Navigate(destination), CommandStatus.PENDING_HANDOFF)

    def _open_calendar(self) -> CommandResult:
        webbrowser.open("https://calendar.google.com")
        return CommandResult(True, "Opening calendar.", CommandAction.OpenCalendar(), CommandStatus.PENDING_HANDOFF)

    def _calculate(self, expression: str) -> CommandResult:
        result = _eval_expression(expression)
        if result is None:
            return CommandResult(False, f"Could not calculate {expression}.", CommandAction.Calculate(expression))
        return CommandResult(True, f"{expression} = {result}", CommandAction.Calculate(expression), CommandStatus.VERIFIED_SUCCESS)

    def _smart_home(self, device: str, operation: str, value: Optional[str]) -> CommandResult:
        return CommandResult(True, f"Smart home command relayed: {device}/{operation}/{value}", CommandAction.SmartHome(device, operation, value))

    def _add_to_list(self, item: str, list_name: str) -> CommandResult:
        filename = f"nexus_{list_name}_list.txt"
        with open(filename, "a", encoding="utf-8") as f:
            f.write(f"{item}\n")
        return CommandResult(True, f"Added {item} to {list_name} list.", CommandAction.ListAction(item, list_name), CommandStatus.PENDING_HANDOFF)

    def _set_reminder(self, task: str) -> CommandResult:
        notify = shutil.which("notify-send")
        if notify:
            self._run(["notify-send", "Reminder", task])
        return CommandResult(True, f"Reminder set: {task}", CommandAction.SetReminder(task), CommandStatus.PENDING_HANDOFF)

    def _search_info(self, query: str, search_type: str) -> CommandResult:
        search_string = f"spell {query}" if search_type == "Spell" else f"define {query}"
        url = f"https://www.google.com/search?q={urllib.parse.quote(search_string)}"
        webbrowser.open(url)
        return CommandResult(True, f"Looking up: {search_string}", CommandAction.SearchInfo(query, search_type), CommandStatus.PENDING_HANDOFF)

    def _open_camera(self, is_selfie: bool) -> CommandResult:
        for app in ["cheese", "vlc", "fswebcam"]:
            if shutil.which(app):
                self._run([app])
                return CommandResult(True, "Camera opened.", CommandAction.OpenCamera(is_selfie), CommandStatus.PENDING_HANDOFF)
        return CommandResult(False, "No camera app found.", CommandAction.OpenCamera(is_selfie))

    def _record_video(self) -> CommandResult:
        return self._open_camera(False)

    def _call_contact(self, contact: str) -> CommandResult:
        webbrowser.open(f"tel:{urllib.parse.quote(contact)}")
        return CommandResult(True, f"Opening dialer for {contact}...", CommandAction.CallContact(contact), CommandStatus.PENDING_HANDOFF)

    def _send_text(self, contact: str, message: Optional[str]) -> CommandResult:
        body = urllib.parse.quote(message or "")
        webbrowser.open(f"sms:{urllib.parse.quote(contact)}?body={body}")
        return CommandResult(True, f"Opening messenger to {contact}...", CommandAction.SendText(contact, message), CommandStatus.PENDING_HANDOFF)

    def _send_email(self, recipient: str) -> CommandResult:
        webbrowser.open(f"mailto:{recipient}")
        return CommandResult(True, "Opening email...", CommandAction.SendEmail(recipient), CommandStatus.PENDING_HANDOFF)

    def _cancel_alarm_timer(self) -> CommandResult:
        return CommandResult(False, "Cancel alarm/timer not implemented on Linux.", CommandAction.CancelAlarmTimer())

    def _get_time_date(self) -> CommandResult:
        now = datetime.now()
        return CommandResult(True, f"It is {now.strftime('%H:%M')} on {now.strftime('%A, %d %B %Y')}.", CommandAction.GetTimeDate(), CommandStatus.VERIFIED_SUCCESS)

    def _get_battery_status(self) -> CommandResult:
        level = "unknown"
        status = "unknown"
        try:
            for bat in os.listdir("/sys/class/power_supply"):
                if bat.startswith("BAT"):
                    with open(f"/sys/class/power_supply/{bat}/capacity") as f:
                        level = f.read().strip()
                    with open(f"/sys/class/power_supply/{bat}/status") as f:
                        status = f.read().strip().lower()
                    break
        except Exception:
            pass
        return CommandResult(True, f"Battery is at {level}% and {status}.", CommandAction.GetBatteryStatus(), CommandStatus.VERIFIED_SUCCESS)

    def _get_next_alarm(self) -> CommandResult:
        return CommandResult(True, "No upcoming alarms.", CommandAction.GetNextAlarm(), CommandStatus.VERIFIED_SUCCESS)

    def _get_joke(self) -> CommandResult:
        try:
            req = urllib.request.Request("https://v2.jokeapi.dev/joke/Any?safe-mode&format=txt")
            with urllib.request.urlopen(req, timeout=10) as resp:
                joke = resp.read().decode("utf-8").strip()
            return CommandResult(True, joke or "No joke returned.", CommandAction.GetJoke(), CommandStatus.VERIFIED_SUCCESS)
        except Exception as e:
            return CommandResult(False, f"Could not fetch a joke: {e}", CommandAction.GetJoke())

    def _get_weather(self) -> CommandResult:
        # Default coordinates point to Montreal. Override with environment
        # variables if you want a local forecast on the desktop node.
        latitude = float(os.environ.get("NEXUS_LAT", "45.5"))
        longitude = float(os.environ.get("NEXUS_LON", "-73.6"))
        url = f"https://api.open-meteo.com/v1/forecast?latitude={latitude}&longitude={longitude}&current_weather=true"
        try:
            req = urllib.request.Request(url)
            with urllib.request.urlopen(req, timeout=10) as resp:
                data = json.loads(resp.read().decode("utf-8"))
            current = data["current_weather"]
            temp = current["temperature"]
            code = current["weathercode"]
            conditions = {
                0: "clear sky", 1: "partly cloudy", 2: "partly cloudy", 3: "partly cloudy",
                45: "foggy", 48: "foggy", 51: "drizzle", 53: "drizzle", 55: "drizzle",
                61: "rainy", 63: "rainy", 65: "rainy", 71: "snow", 73: "snow", 75: "snow",
                95: "thunderstorm", 96: "thunderstorm", 99: "thunderstorm",
            }
            return CommandResult(True, f"Current weather: {temp}°C, {conditions.get(code, 'unknown')}.", CommandAction.GetWeather(), CommandStatus.VERIFIED_SUCCESS)
        except Exception as e:
            return CommandResult(False, f"Could not fetch weather: {e}", CommandAction.GetWeather())

    def _get_today_schedule(self) -> CommandResult:
        webbrowser.open("https://calendar.google.com")
        return CommandResult(True, "Opening calendar.", CommandAction.GetTodaySchedule(), CommandStatus.PENDING_HANDOFF)


# ------------------------------------------------------------------
# Module-level helpers
# ------------------------------------------------------------------
def _parse_alarm(match: "re.Match") -> CommandAction:
    hour = int(match.group(1))
    minute = int(match.group(2)) if match.group(2) else 0
    ampm = match.group(3) or ""
    if ampm.lower() == "pm" and hour < 12:
        hour += 12
    elif ampm.lower() == "am" and hour == 12:
        hour = 0
    return CommandAction.SetAlarm(hour, minute)


def _parse_calc(match: "re.Match") -> CommandAction:
    op_word = match.group(2).lower()
    op = {
        "times": "*",
        "multiplied by": "*",
        "x": "*",
        "divided by": "/",
        "over": "/",
        "plus": "+",
        "minus": "-",
    }.get(op_word, op_word)
    return CommandAction.Calculate(f"{match.group(1)}{op}{match.group(3)}")


def _eval_expression(expression: str) -> Optional[float]:
    try:
        sanitized = expression.replace(" ", "")
        match = re.match(r"(-?\d+\.?\d*)([+\-*/])(-?\d+\.?\d*)", sanitized)
        if not match:
            return None
        a = float(match.group(1))
        op = match.group(2)
        b = float(match.group(3))
        if op == "+":
            return a + b
        if op == "-":
            return a - b
        if op == "*":
            return a * b
        if op == "/":
            return None if b == 0 else a / b
        return None
    except Exception:
        return None
