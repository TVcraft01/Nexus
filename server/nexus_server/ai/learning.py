# AI Learning Repository
#
# Ported from existing learning.py. Local JSON-backed store of successful
# (input → action) mappings for fuzzy matching.

from __future__ import annotations

import json
import os
import time
from typing import Optional

from nexus_server.storage import storage_path


class LearningRepository:
    def __init__(self):
        self.json_file = storage_path("learned_commands.json")
        self._commands: list = []
        self._load()

    def _load(self) -> None:
        if os.path.exists(self.json_file):
            try:
                with open(self.json_file, "r") as f:
                    self._commands = json.load(f)
            except Exception:
                self._commands = []

    def _save(self) -> None:
        with open(self.json_file, "w") as f:
            json.dump(self._commands, f, indent=2)

    def record_success(self, input_text: str, action) -> None:
        normalized = input_text.strip().lower()
        action_name = getattr(action, "name", str(action))
        action_args = getattr(action, "args", {})

        for entry in self._commands:
            if entry["input"] == normalized:
                entry["success_count"] = entry.get("success_count", 1) + 1
                entry["last_used"] = time.time()
                self._save()
                return

        self._commands.append({
            "input": normalized,
            "action_name": action_name,
            "args": action_args,
            "success_count": 1,
            "last_used": time.time(),
        })
        self._save()

    def find_similar_action(self, input_text: str,
                           threshold: float = 0.6) -> Optional["CommandAction"]:
        from nexus_server.models import CommandAction
        normalized = input_text.strip().lower()
        tokens = set(normalized.split())
        best, best_score = None, 0.0

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
