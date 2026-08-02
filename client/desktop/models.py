"""Data models that mirror the Android Nexus types."""

from __future__ import annotations

import base64
import dataclasses
from dataclasses import dataclass, field
from enum import Enum, auto
from typing import Any, Dict, List, Optional


# Commands that only read information and have no side effects.
SAFE_COMMANDS = {
    "GET_TIME_DATE",
    "GET_BATTERY_STATUS",
    "GET_NEXT_ALARM",
    "GET_JOKE",
    "GET_WEATHER",
    "GET_TODAY_SCHEDULE",
    "CALCULATE",
    "ROLL_DICE",
    "FLIP_COIN",
}


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


@dataclass
class CommandAction:
    name: str
    args: Dict[str, Any] = field(default_factory=dict)

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
    def ToggleWifi(cls, enable: bool) -> "CommandAction":
        return cls("TOGGLE_WIFI", {"enable": enable})

    @classmethod
    def ToggleBluetooth(cls, enable: bool) -> "CommandAction":
        return cls("TOGGLE_BLUETOOTH", {"enable": enable})

    @classmethod
    def SetBrightness(cls, level: int) -> "CommandAction":
        return cls("SET_BRIGHTNESS", {"level": level})

    @classmethod
    def PlayMedia(cls, query: str) -> "CommandAction":
        return cls("PLAY_MEDIA", {"query": query})

    @classmethod
    def PauseMedia(cls, query: str = "") -> "CommandAction":
        return cls("PAUSE_MEDIA", {"query": query})

    @classmethod
    def PlayMediaApp(cls, query: str, app_name: str) -> "CommandAction":
        return cls("PLAY_MEDIA_APP", {"query": query, "app_name": app_name})

    @classmethod
    def MediaControl(cls, command: str) -> "CommandAction":
        return cls("MEDIA_CONTROL", {"command": command})

    @classmethod
    def SetVolume(cls, percent: int) -> "CommandAction":
        return cls("SET_VOLUME", {"percent": percent})

    @classmethod
    def AdjustVolume(cls, delta: int) -> "CommandAction":
        return cls("ADJUST_VOLUME", {"delta": delta})

    @classmethod
    def MuteVolume(cls) -> "CommandAction":
        return cls("MUTE_VOLUME", {})

    @classmethod
    def OpenSettings(cls, page: str) -> "CommandAction":
        return cls("OPEN_SETTINGS", {"page": page})

    @classmethod
    def MeshRelay(cls, payload: str) -> "CommandAction":
        return cls("MESH_RELAY", {"payload": payload})

    @classmethod
    def ToggleFlashlight(cls, enable: bool) -> "CommandAction":
        return cls("TOGGLE_FLASHLIGHT", {"enable": enable})

    @classmethod
    def SetTimer(cls, seconds: int, label: Optional[str] = None) -> "CommandAction":
        return cls("SET_TIMER", {"seconds": seconds, "label": label})

    @classmethod
    def SetAlarm(cls, hour: int, minute: int, label: Optional[str] = None, repeating: bool = False) -> "CommandAction":
        return cls("SET_ALARM", {"hour": hour, "minute": minute, "label": label, "repeating": repeating})

    @classmethod
    def TakeNote(cls, content: str) -> "CommandAction":
        return cls("TAKE_NOTE", {"content": content})

    @classmethod
    def RollDice(cls, sides: int = 6) -> "CommandAction":
        return cls("ROLL_DICE", {"sides": sides})

    @classmethod
    def FlipCoin(cls) -> "CommandAction":
        return cls("FLIP_COIN", {})

    @classmethod
    def ToggleDnd(cls, enable: bool) -> "CommandAction":
        return cls("TOGGLE_DND", {"enable": enable})

    @classmethod
    def Navigate(cls, destination: str) -> "CommandAction":
        return cls("NAVIGATE", {"destination": destination})

    @classmethod
    def OpenCalendar(cls) -> "CommandAction":
        return cls("OPEN_CALENDAR", {})

    @classmethod
    def Calculate(cls, expression: str) -> "CommandAction":
        return cls("CALCULATE", {"expression": expression})

    @classmethod
    def SmartHome(cls, device: str, operation: str, value: Optional[str]) -> "CommandAction":
        return cls("SMART_HOME", {"device": device, "operation": operation, "value": value})

    @classmethod
    def ListAction(cls, item: str, list_name: str) -> "CommandAction":
        return cls("LIST_ACTION", {"item": item, "list_name": list_name})

    @classmethod
    def SetReminder(cls, task: str) -> "CommandAction":
        return cls("SET_REMINDER", {"task": task})

    @classmethod
    def SearchInfo(cls, query: str, search_type: str) -> "CommandAction":
        return cls("SEARCH_INFO", {"query": query, "search_type": search_type})

    @classmethod
    def OpenCamera(cls, is_selfie: bool) -> "CommandAction":
        return cls("OPEN_CAMERA", {"is_selfie": is_selfie})

    @classmethod
    def RecordVideo(cls) -> "CommandAction":
        return cls("RECORD_VIDEO", {})

    @classmethod
    def CallContact(cls, contact: str) -> "CommandAction":
        return cls("CALL_CONTACT", {"contact": contact})

    @classmethod
    def SendText(cls, contact: str, message: Optional[str]) -> "CommandAction":
        return cls("SEND_TEXT", {"contact": contact, "message": message})

    @classmethod
    def SendEmail(cls, recipient: str) -> "CommandAction":
        return cls("SEND_EMAIL", {"recipient": recipient})

    @classmethod
    def CancelAlarmTimer(cls) -> "CommandAction":
        return cls("CANCEL_ALARM_TIMER", {})

    @classmethod
    def GetTimeDate(cls) -> "CommandAction":
        return cls("GET_TIME_DATE", {})

    @classmethod
    def GetBatteryStatus(cls) -> "CommandAction":
        return cls("GET_BATTERY_STATUS", {})

    @classmethod
    def GetNextAlarm(cls) -> "CommandAction":
        return cls("GET_NEXT_ALARM", {})

    @classmethod
    def GetJoke(cls) -> "CommandAction":
        return cls("GET_JOKE", {})

    @classmethod
    def GetWeather(cls) -> "CommandAction":
        return cls("GET_WEATHER", {})

    @classmethod
    def GetTodaySchedule(cls) -> "CommandAction":
        return cls("GET_TODAY_SCHEDULE", {})

    @classmethod
    def Unknown(cls, raw: str) -> "CommandAction":
        return cls("UNKNOWN", {"raw": raw})

    @classmethod
    def Rejected(cls, reason: str) -> "CommandAction":
        return cls("REJECTED", {"reason": reason})

    def __eq__(self, other: object) -> bool:
        if not isinstance(other, CommandAction):
            return NotImplemented
        return self.name == other.name and self.args == other.args

    def __hash__(self) -> int:
        return hash((self.name, tuple(sorted(self.args.items()))))


@dataclass
class ParsedIntent:
    """Result of parsing a command string, including confidence and source."""
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

    def __post_init__(self):
        # Only default the status when it is FAILED and the caller did not
        # supply an explicit status. This preserves Android-style handoffs
        # such as success=False + status=PENDING_HANDOFF.
        if self.status == CommandStatus.FAILED and self.success:
            self.status = CommandStatus.VERIFIED_SUCCESS
        elif self.status == CommandStatus.FAILED and not self.success:
            # leave as FAILED
            pass


@dataclass
class MeshPayload:
    command: Optional[str] = None
    context: Optional[str] = None
    result: Optional[str] = None
    success: bool = True

    def to_json(self) -> str:
        import json
        return json.dumps({
            "command": self.command,
            "context": self.context,
            "result": self.result,
            "success": self.success,
        }, separators=(",", ":"))

    @classmethod
    def from_json(cls, json_string: str) -> "MeshPayload":
        import json
        data = json.loads(json_string)
        return cls(
            command=data.get("command") or None,
            context=data.get("context") or None,
            result=data.get("result") or None,
            success=data.get("success", True),
        )


@dataclass
class MeshMessage:
    sender_id: str
    type: MeshMessageType
    iv: bytes
    payload: bytes
    timestamp: int = field(default_factory=lambda: int(__import__("time").time() * 1000))

    def to_json(self) -> str:
        import json
        return json.dumps({
            "senderId": self.sender_id,
            "type": self.type.name,
            "iv": base64.b64encode(self.iv).decode("ascii"),
            "payload": base64.b64encode(self.payload).decode("ascii"),
            "timestamp": self.timestamp,
        }, separators=(",", ":"))

    @classmethod
    def from_json(cls, json_string: str) -> "MeshMessage":
        import json
        data = json.loads(json_string)
        return cls(
            sender_id=data["senderId"],
            type=MeshMessageType[data["type"]],
            iv=base64.b64decode(data["iv"]),
            payload=base64.b64decode(data["payload"]),
            timestamp=data.get("timestamp", int(__import__("time").time() * 1000)),
        )


@dataclass
class MeshNode:
    id: str
    name: str
    address: str
    port: Optional[int] = None
    transport: TransportType = TransportType.WIFI_NSD
    last_seen: int = field(default_factory=lambda: int(__import__("time").time() * 1000))
    is_paired: bool = False

    def copy_with_paired(self, paired: bool) -> "MeshNode":
        return MeshNode(
            id=self.id,
            name=self.name,
            address=self.address,
            port=self.port,
            transport=self.transport,
            last_seen=int(__import__("time").time() * 1000),
            is_paired=paired,
        )

    @property
    def is_reachable(self) -> bool:
        import time
        return (int(time.time() * 1000) - self.last_seen) < 60_000


@dataclass
class SanitizedInput:
    original: str
    sanitized: str
    command_string: str
    threat_level: ThreatLevel
    rejected: bool
    reason: str = ""


@dataclass
class UserDialectRule:
    id: str
    pattern: str
    action_type: str
    payload: str = ""
    enabled: bool = True
    priority: int = 100

    def to_dict(self) -> Dict[str, Any]:
        return dataclasses.asdict(self)

    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> "UserDialectRule":
        return cls(
            id=data.get("id", ""),
            pattern=data.get("pattern", ""),
            action_type=data.get("action_type", ""),
            payload=data.get("payload", ""),
            enabled=data.get("enabled", True),
            priority=data.get("priority", 100),
        )
