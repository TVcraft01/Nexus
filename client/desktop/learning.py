"""Lightweight, privacy-first command learning store.

Keeps a local JSON file of successful (input -> action) mappings. When the
engine cannot parse a command with built-in rules, it tries a fuzzy match
against previously successful commands.
"""

from __future__ import annotations

import json
import os
import time
from typing import Optional

from .models import CommandAction


class LearningRepository:
    def __init__(self, storage_path: str = "learned_commands.json"):
        self.json_file = storage_path
        self._commands: list[dict] = []
        self._load()

    def _load(self) -> None:
        if not os.path.exists(self.json_file):
            self._commands = []
            return
        try:
            with open(self.json_file, "r", encoding="utf-8") as f:
                self._commands = json.load(f)
        except Exception:
            self._commands = []

    def _save(self) -> None:
        with open(self.json_file, "w", encoding="utf-8") as f:
            json.dump(self._commands, f, indent=2)

    def record_success(self, input_text: str, action: CommandAction) -> None:
        normalized = input_text.strip().lower()
        for entry in self._commands:
            if entry["input"] == normalized:
                entry["success_count"] = entry.get("success_count", 1) + 1
                entry["last_used"] = time.time()
                self._save()
                return
        self._commands.append(
            {
                "input": normalized,
                "action_name": action.name,
                "args": action.args,
                "success_count": 1,
                "last_used": time.time(),
            }
        )
        self._save()

    def find_similar_action(self, input_text: str, threshold: float = 0.6) -> Optional[CommandAction]:
        normalized = input_text.strip().lower()
        tokens = set(normalized.split())

        best: Optional[dict] = None
        best_score = 0.0

        for entry in self._commands:
            learned_tokens = set(entry["input"].split())
            overlap = len(tokens & learned_tokens)
            union = len(tokens | learned_tokens)
            if union == 0:
                continue
            score = overlap / union
            if score >= threshold and score > best_score:
                best_score = score
                best = entry

        if best is None:
            return None

        try:
            return CommandAction(best["action_name"], best.get("args", {}))
        except Exception:
            return None
