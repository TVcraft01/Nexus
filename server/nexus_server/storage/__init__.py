# Storage - Local Data Persistence Layer
#
# Manages JSON-backed persistence for user rules, settings, and learning data.

from __future__ import annotations

import json
import os
import uuid
from typing import Any, Dict, List

# Global storage directory (set by configure_storage)
_storage_dir: str = ".nexus"


def configure_storage(path: str) -> None:
    global _storage_dir
    _storage_dir = path
    os.makedirs(path, exist_ok=True)


def get_storage_dir() -> str:
    return _storage_dir


def storage_path(filename: str) -> str:
    return os.path.join(_storage_dir, filename)


# ---------------------------------------------------------------------------
# User Rules Repository
# ---------------------------------------------------------------------------

class UserDialectRule:
    def __init__(self, id: str, pattern: str, action_type: str,
                 payload: str = "", enabled: bool = True, priority: int = 100):
        self.id = id
        self.pattern = pattern
        self.action_type = action_type
        self.payload = payload
        self.enabled = enabled
        self.priority = priority

    def to_dict(self) -> Dict[str, Any]:
        return {
            "id": self.id, "pattern": self.pattern,
            "action_type": self.action_type, "payload": self.payload,
            "enabled": self.enabled, "priority": self.priority,
        }

    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> "UserDialectRule":
        return cls(**data)


class UserRulesRepository:
    def __init__(self) -> None:
        self.json_file = storage_path("user_dialect_rules.json")
        self._rules: List[UserDialectRule] = []
        self._load()

    def _load(self) -> None:
        if os.path.exists(self.json_file):
            try:
                with open(self.json_file, "r") as f:
                    self._rules = [UserDialectRule.from_dict(d) for d in json.load(f)]
            except Exception:
                self._rules = []

    def _save(self) -> None:
        with open(self.json_file, "w") as f:
            json.dump([r.to_dict() for r in self._rules], f, indent=2)

    def get_enabled_rules(self) -> List[UserDialectRule]:
        return [r for r in self._rules if r.enabled]

    def add_rule(self, pattern: str, action_type: str,
                payload: str = "", priority: int = 100) -> UserDialectRule:
        rule = UserDialectRule(
            id=str(uuid.uuid4()), pattern=pattern,
            action_type=action_type, payload=payload,
            enabled=True, priority=priority,
        )
        self._rules.append(rule)
        self._save()
        return rule

    def delete_rule(self, rule_id: str) -> bool:
        before = len(self._rules)
        self._rules = [r for r in self._rules if r.id != rule_id]
        if len(self._rules) < before:
            self._save()
            return True
        return False


# ---------------------------------------------------------------------------
# Settings Repository
# ---------------------------------------------------------------------------

class SettingsRepository:
    def __init__(self) -> None:
        self.settings_file = storage_path("settings.json")
        self._settings: Dict[str, Any] = {}
        self._load()

    def get(self, key: str, default: Any = None) -> Any:
        return self._settings.get(key, default)

    def set(self, key: str, value: Any) -> None:
        self._settings[key] = value
        self._save()

    def _load(self) -> None:
        if os.path.exists(self.settings_file):
            try:
                with open(self.settings_file, "r") as f:
                    self._settings = json.load(f)
            except Exception:
                self._settings = {}

    def _save(self) -> None:
        with open(self.settings_file, "w") as f:
            json.dump(self._settings, f, indent=2)
