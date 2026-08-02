# Nexus Data Models - mirrors the Android/Kotlin types
#
# Shared data models used across all Nexus modules.
# Compatible with the existing Android and desktop protocols.

from __future__ import annotations

import base64
import dataclasses
import json
import time
from dataclasses import dataclass, field
from enum import Enum, auto
from typing import Any, Dict, List, Optional


# ---------------------------------------------------------------------------
# Safe commands (read-only, no side effects)
# ---------------------------------------------------------------------------
SAFE_COMMANDS = {
    "GET_TIME_DATE", "GET_BATTERY_STATUS", "GET_NEXT_ALARM",
    "GET_JOKE", "GET_WEATHER", "GET_TODAY_SCHEDULE",
    "CALCULATE", "ROLL_DICE", "FLIP_COIN",
}


# ---------------------------------------------------------------------------
# Enums
# ---------------------------------------------------------------------------

class CommandStatus(Enum):
    VERIFIED_SUCCESS = "VERIFIED_SUCCESS"
    PENDING_HANDOFF = "PENDING_HANDOFF"
    FAILED = "FAILED"


class TransportType(Enum):
    BLE = "BLE"
    WIFI_NSD = "WIFI_NSD"


class MeshMessageType(Enum):
    COMMAND = "COMMAND"
    QUERY = "QUERY"
    CONTEXT = "CONTEXT"
    PAIRING_REQUEST = "PAIRING_REQUEST"
    PAIRING_RESPONSE = "PAIRING_RESPONSE"
    RESULT = "RESULT"


class ThreatLevel(Enum):
    SAFE = "SAFE"
    SUSPICIOUS = "SUSPICIOUS"
    DANGEROUS = "DANGEROUS"


# ---------------------------------------------------------------------------
# Core Models
# ---------------------------------------------------------------------------

@dataclass
class CommandAction:
    name: str
    args: Dict[str, Any] = field(default_factory=dict)

    def __eq__(self, other: object) -> bool:
        if not isinstance(other, CommandAction):
            return NotImplemented
        return self.name == other.name and self.args == other.args

    def __hash__(self) -> int:
        return hash((self.name, tuple(sorted(self.args.items()))))

    # Factory methods
    @classmethod
    def OpenApp(cls, package_name: str) -> "CommandAction":
        return cls("OPEN_APP", {"package_name": package_name})

    @classmethod
    def OpenWebsite(cls, url: str) -> "CommandAction":
        return cls("OPEN_WEBSITE", {"url": url})

    @classmethod
    def WebSearch(cls, query: str) -> "CommandAction":
        return cls("WEB_SEARCH", {"query": query})

    @classmethod
    def SetVolume(cls, percent: int) -> "CommandAction":
        return cls("SET_VOLUME", {"percent": percent})

    @classmethod
    def SetBrightness(cls, level: int) -> "CommandAction":
        return cls("SET_BRIGHTNESS", {"level": level})

    @classmethod
    def PlayMedia(cls, query: str) -> "CommandAction":
        return cls("PLAY_MEDIA", {"query": query})

    @classmethod
    def SetTimer(cls, seconds: int, label: Optional[str] = None) -> "CommandAction":
        return cls("SET_TIMER", {"seconds": seconds, "label": label})

    @classmethod
    def SetAlarm(cls, hour: int, minute: int, label: Optional[str] = None,
                repeating: bool = False) -> "CommandAction":
        return cls("SET_ALARM", {"hour": hour, "minute": minute,
                                 "label": label, "repeating": repeating})

    @classmethod
    def TakeNote(cls, content: str) -> "CommandAction":
        return cls("TAKE_NOTE", {"content": content})

    @classmethod
    def Navigate(cls, destination: str) -> "CommandAction":
        return cls("NAVIGATE", {"destination": destination})

    @classmethod
    def GetTimeDate(cls) -> "CommandAction":
        return cls("GET_TIME_DATE", {})

    @classmethod
    def GetWeather(cls) -> "CommandAction":
        return cls("GET_WEATHER", {})

    @classmethod
    def Unknown(cls, raw: str) -> "CommandAction":
        return cls("UNKNOWN", {"raw": raw})

    @classmethod
    def Rejected(cls, reason: str) -> "CommandAction":
        return cls("REJECTED", {"reason": reason})

    @classmethod
    def ToggleWifi(cls, enable: bool) -> "CommandAction":
        return cls("TOGGLE_WIFI", {"enable": enable})

    @classmethod
    def ToggleBluetooth(cls, enable: bool) -> "CommandAction":
        return cls("TOGGLE_BLUETOOTH", {"enable": enable})

    @classmethod
    def ToggleFlashlight(cls, enable: bool) -> "CommandAction":
        return cls("TOGGLE_FLASHLIGHT", {"enable": enable})

    @classmethod
    def ToggleDnd(cls, enable: bool) -> "CommandAction":
        return cls("TOGGLE_DND", {"enable": enable})

    @classmethod
    def SetReminder(cls, task: str) -> "CommandAction":
        return cls("SET_REMINDER", {"task": task})

    @classmethod
    def RollDice(cls, sides: int = 6) -> "CommandAction":
        return cls("ROLL_DICE", {"sides": sides})

    @classmethod
    def FlipCoin(cls) -> "CommandAction":
        return cls("FLIP_COIN", {})

    @classmethod
    def GetJoke(cls) -> "CommandAction":
        return cls("GET_JOKE", {})

    @classmethod
    def Calculate(cls, expression: str) -> "CommandAction":
        return cls("CALCULATE", {"expression": expression})

    @classmethod
    def AdjustVolume(cls, delta: int) -> "CommandAction":
        return cls("ADJUST_VOLUME", {"delta": delta})

    @classmethod
    def MuteVolume(cls) -> "CommandAction":
        return cls("MUTE_VOLUME", {})

    @classmethod
    def MediaControl(cls, command: str) -> "CommandAction":
        return cls("MEDIA_CONTROL", {"command": command})


@dataclass
class ParsedIntent:
    """Result of parsing a command string."""
    action: CommandAction
    confidence: float
    source: str  # "user_rule", "regex", "llm", "unknown"

    def is_confident(self, threshold: float = 0.9) -> bool:
        return self.confidence >= threshold


@dataclass
class CommandResult:
    success: bool
    message: str
    action: CommandAction
    status: CommandStatus = CommandStatus.FAILED
    requires_intern_choice: bool = False
    choices: List[str] = field(default_factory=list)
    original_input: str = ""


@dataclass
class MeshPayload:
    command: Optional[str] = None
    context: Optional[str] = None
    result: Optional[str] = None
    success: bool = True

    def to_json(self) -> str:
        return json.dumps({
            "command": self.command,
            "context": self.context,
            "result": self.result,
            "success": self.success,
        })

    @classmethod
    def from_json(cls, json_string: str) -> "MeshPayload":
        data = json.loads(json_string)
        return cls(**data)


@dataclass
class MeshMessage:
    sender_id: str
    type: MeshMessageType
    iv: bytes
    payload: bytes
    timestamp: int = field(default_factory=lambda: int(time.time() * 1000))

    def to_json(self) -> str:
        return json.dumps({
            "senderId": self.sender_id,
            "type": self.type.name,
            "iv": base64.b64encode(self.iv).decode("ascii"),
            "payload": base64.b64encode(self.payload).decode("ascii"),
            "timestamp": self.timestamp,
        })

    @classmethod
    def from_json(cls, json_string: str) -> "MeshMessage":
        data = json.loads(json_string)
        return cls(
            sender_id=data["senderId"],
            type=MeshMessageType[data["type"]],
            iv=base64.b64decode(data["iv"]),
            payload=base64.b64decode(data["payload"]),
            timestamp=data.get("timestamp", int(time.time() * 1000)),
        )


@dataclass
class MeshNode:
    id: str
    name: str
    address: str
    port: Optional[int] = None
    transport: TransportType = TransportType.WIFI_NSD
    last_seen: int = field(default_factory=lambda: int(time.time() * 1000))
    is_paired: bool = False

    @property
    def is_reachable(self) -> bool:
        return (int(time.time() * 1000) - self.last_seen) < 60_000


@dataclass
class SanitizedInput:
    original: str
    sanitized: str
    command_string: str
    threat_level: ThreatLevel
    rejected: bool
    reason: str = ""
