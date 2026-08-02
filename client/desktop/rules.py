"""User-defined command rules repository (JSON-backed)."""

from __future__ import annotations

import json
import os
import uuid
from typing import List

from .models import UserDialectRule


class UserRulesRepository:
    def __init__(self, storage_path: str = "user_dialect_rules.json"):
        self.json_file = storage_path
        self._rules: List[UserDialectRule] = []
        self._load()

    def _load(self) -> None:
        if os.path.exists(self.json_file):
            try:
                with open(self.json_file, "r", encoding="utf-8") as f:
                    data = json.load(f)
                self._rules = [UserDialectRule.from_dict(item) for item in data]
            except Exception:
                self._rules = []
        else:
            self._rules = []

    def _save(self) -> None:
        with open(self.json_file, "w", encoding="utf-8") as f:
            json.dump([rule.to_dict() for rule in self._rules], f, indent=2)

    def get_enabled_rules(self) -> List[UserDialectRule]:
        return [rule for rule in self._rules if rule.enabled]

    def get_all_rules(self) -> List[UserDialectRule]:
        return list(self._rules)

    def add_rule(self, pattern: str, action_type: str, payload: str = "", priority: int = 100) -> UserDialectRule:
        rule = UserDialectRule(
            id=str(uuid.uuid4()),
            pattern=pattern,
            action_type=action_type,
            payload=payload,
            enabled=True,
            priority=priority,
        )
        self._rules.append(rule)
        self._save()
        return rule

    def delete_rule(self, rule_id: str) -> bool:
        before = len(self._rules)
        self._rules = [rule for rule in self._rules if rule.id != rule_id]
        if len(self._rules) < before:
            self._save()
            return True
        return False

    def import_from_json(self, json_string: str) -> bool:
        try:
            data = json.loads(json_string)
            self._rules = [UserDialectRule.from_dict(item) for item in data]
            self._save()
            return True
        except Exception:
            return False

    def export_to_json(self) -> str:
        return json.dumps([rule.to_dict() for rule in self._rules], indent=2)
