# Proactive Assistant - Routine Learning & Proactive Reminders
#
# Nexus continuously monitors user actions to learn routines and sends
# proactive reminders without being explicitly asked.
#
# Algorithm: Bayesian time-slot prediction with pattern matching.
# - Tracks actions per hour-of-day and day-of-week.
# - Uses frequency analysis to detect routines.
# - Generates proactive alerts when confidence exceeds threshold.

from __future__ import annotations

import json
import logging
import os
import time
from collections import defaultdict
from datetime import datetime
from typing import Any, Dict, List, Optional, Tuple

logger = logging.getLogger("nexus.ai.proactive")


class ProactiveAssistant:
    """Learns user routines and provides proactive reminders."""

    def __init__(self, learning_repo, storage_dir: str = ".nexus") -> None:
        self.learning_repo = learning_repo
        self.storage_dir = storage_dir
        self.routine_file = os.path.join(storage_dir, "routines.json")

        # Action history: list of (timestamp, action_name, context)
        self.action_history: List[Tuple[float, str, str]] = []

        # Routine model: (day_of_week, hour) → list of action counts
        self.routine_model: Dict[Tuple[int, int], Dict[str, int]] = defaultdict(
            lambda: defaultdict(int)
        )

        # Confidence threshold for proactive alerts
        self.confidence_threshold = 0.65

        # Tracked routine types
        self.routine_types = ["SET_ALARM", "SET_TIMER", "TAKE_NOTE", "SET_REMINDER",
                             "OPEN_APP", "PLAY_MEDIA", "GET_WEATHER", "NAVIGATE"]

        self._load()
        self._running = False

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    def start(self) -> None:
        """Start the proactive monitoring loop."""
        self._running = True
        logger.info("Proactive assistant started")

    def stop(self) -> None:
        """Stop monitoring."""
        self._running = False
        self._save()

    def record_action(self, user_input: str, action) -> None:
        """Record a user action to build routine patterns."""
        now = time.time()
        dt = datetime.now()
        key = (dt.weekday(), dt.hour)
        action_name = getattr(action, "name", str(action))

        self.action_history.append((now, action_name, user_input))
        self.routine_model[key][action_name] += 1

        # Periodically save
        if len(self.action_history) % 25 == 0:
            self._save()

    def get_suggestions(self, max_suggestions: int = 5) -> List[Dict[str, Any]]:
        """Get proactive suggestions for the current time slot."""
        now = datetime.now()
        current_slot = (now.weekday(), now.hour)

        suggestions = []

        # Check current time slot for high-confidence routines
        slot_routines = self.routine_model.get(current_slot, {})
        total_in_slot = sum(slot_routines.values()) if slot_routines else 1

        for action_name, count in sorted(slot_routines.items(),
                                          key=lambda x: -x[1]):
            confidence = count / total_in_slot if total_in_slot > 0 else 0
            if confidence >= self.confidence_threshold:
                suggestions.append({
                    "action": action_name,
                    "confidence": round(confidence, 2),
                    "message": self._generate_suggestion_message(action_name, confidence),
                    "time_slot": f"{now.strftime('%A')} at {now.hour:02d}:00",
                })

        # Also check next hour
        next_slot = (now.weekday(), (now.hour + 1) % 24)
        next_routines = self.routine_model.get(next_slot, {})
        total_next = sum(next_routines.values()) if next_routines else 1

        for action_name, count in sorted(next_routines.items(),
                                          key=lambda x: -x[1]):
            confidence = count / total_next if total_next > 0 else 0
            if confidence >= self.confidence_threshold:
                suggestions.append({
                    "action": action_name,
                    "confidence": round(confidence, 2),
                    "message": f"Up next: {self._generate_suggestion_message(action_name, confidence)}",
                    "time_slot": f"{now.strftime('%A')} at {(now.hour + 1) % 24:02d}:00",
                })

        return suggestions[:max_suggestions]

    def get_todays_routine(self) -> List[Dict[str, Any]]:
        """Get the predicted routine for the entire day."""
        today = datetime.now().weekday()
        routine = []

        for hour in range(24):
            slot_routines = self.routine_model.get((today, hour), {})
            total = sum(slot_routines.values()) if slot_routines else 1
            for action_name, count in sorted(slot_routines.items(),
                                              key=lambda x: -x[1]):
                confidence = count / total if total > 0 else 0
                if confidence >= 0.3:  # Lower threshold for daily view
                    routine.append({
                        "hour": hour,
                        "action": action_name,
                        "confidence": round(confidence, 2),
                        "count": count,
                    })

        return sorted(routine, key=lambda x: x["hour"])

    def get_proactive_reminder(self) -> Optional[str]:
        """Return a proactive reminder if one is due (e.g., medication)."""
        suggestions = self.get_suggestions(max_suggestions=3)
        if suggestions:
            top = suggestions[0]
            if top["confidence"] >= 0.7:
                return top["message"]
        return None

    # ------------------------------------------------------------------
    # Internal
    # ------------------------------------------------------------------

    def _generate_suggestion_message(self, action_name: str, confidence: float) -> str:
        """Generate a human-friendly reminder message."""
        templates = {
            "SET_ALARM": "You usually set an alarm around this time.",
            "SET_TIMER": "You often set a timer around this time.",
            "TAKE_NOTE": "You frequently take notes at this time.",
            "SET_REMINDER": "You have reminders due around now.",
            "PLAY_MEDIA": "You often listen to music around this time.",
            "GET_WEATHER": "You usually check the weather now.",
            "NAVIGATE": "You frequently navigate from here at this time.",
            "OPEN_APP": "You regularly open an app around this time.",
        }
        base = templates.get(action_name, f"Routine detected: {action_name}")
        if confidence >= 0.9:
            return f"🔔 {base} (very high confidence)"
        elif confidence >= 0.7:
            return f"💡 {base}"
        return f"📋 {base}"

    def _save(self) -> None:
        """Persist routine data to disk."""
        try:
            data = {
                "routines": {
                    f"{d}_{h}": dict(actions)
                    for (d, h), actions in self.routine_model.items()
                },
                "history_count": len(self.action_history),
            }
            with open(self.routine_file, "w", encoding="utf-8") as f:
                json.dump(data, f, indent=2)
        except Exception as e:
            logger.warning(f"Failed to save routines: {e}")

    def _load(self) -> None:
        """Load routine data from disk."""
        if not os.path.exists(self.routine_file):
            return
        try:
            with open(self.routine_file, "r", encoding="utf-8") as f:
                data = json.load(f)
            for key, actions in data.get("routines", {}).items():
                parts = key.split("_")
                if len(parts) == 2:
                    d, h = int(parts[0]), int(parts[1])
                    self.routine_model[(d, h)] = defaultdict(int, actions)
            logger.info(f"Loaded routines for {len(self.routine_model)} time slots")
        except Exception as e:
            logger.warning(f"Failed to load routines: {e}")
