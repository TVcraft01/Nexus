# Proactive Assistant — Phase 4
#
# Enhanced routine learning with ML-based pattern detection and proactive notifications.
#
# Features:
#   - Bayesian time-slot prediction with Laplace smoothing
#   - Action sequence prediction (Markov chain — what action follows what)
#   - Day-type awareness (weekday vs weekend patterns)
#   - Streak detection (consecutive same-action days)
#   - 15-minute precision time blocks
#   - Desktop notification system (notify-send, osascript)
#   - Scheduled alert polling
#   - Notification history and dismissal

from __future__ import annotations

import json
import logging
import os
import platform
import subprocess
import threading
import time
from collections import defaultdict
from datetime import datetime
from typing import Any, Callable, Dict, List, Optional, Tuple

logger = logging.getLogger("nexus.ai.proactive")


# ---------------------------------------------------------------------------
# Proactive Assistant
# ---------------------------------------------------------------------------

class ProactiveAssistant:
    """Learns user routines with ML-based pattern detection and sends
    proactive reminders via desktop notifications."""

    def __init__(self, learning_repo, storage_dir: str = ".nexus") -> None:
        self.learning_repo = learning_repo
        self.storage_dir = storage_dir
        self.routine_file = os.path.join(storage_dir, "routines.json")

        # ---- Action history ----
        self.action_history: List[Tuple[float, str, str]] = []

        # ---- Models (protected by _model_lock) ----
        self._model_lock = threading.Lock()

        self.routine_model: Dict[Tuple[int, int], Dict[str, int]] = defaultdict(
            lambda: defaultdict(int)
        )
        self.fine_model: Dict[Tuple[int, int, int], Dict[str, int]] = defaultdict(
            lambda: defaultdict(int)
        )
        self.sequence_model: Dict[str, Dict[str, int]] = defaultdict(
            lambda: defaultdict(int)
        )
        self._last_action: Optional[str] = None
        self.streaks: Dict[str, Tuple[int, str]] = {}
        self.weekday_model: Dict[int, Dict[str, int]] = defaultdict(lambda: defaultdict(int))
        self.weekend_model: Dict[int, Dict[str, int]] = defaultdict(lambda: defaultdict(int))

        # ---- Notification history ----
        self.notifications: List[Dict[str, Any]] = []
        self._notification_lock = threading.Lock()
        self._last_notify_time: Dict[str, float] = {}

        # ---- Config ----
        self.confidence_threshold = 0.55
        self.suggestion_high_confidence = 0.7
        self.max_notify_frequency = 3600  # Don't repeat same reminder within 1 hour
        # Reminder rate limiting — per-key dedup
        self._last_notify_time: Dict[str, float] = {}

        self._load()

    # ------------------------------------------------------------------
    # Lifecycle
    # ------------------------------------------------------------------

    def start(self, check_interval_s: int = 60) -> None:
        """Start the proactive monitoring and notification scheduler."""
        self._running = True
        self._scheduler_thread = threading.Thread(
            target=self._reminder_loop,
            args=(check_interval_s,),
            daemon=True,
        )
        self._scheduler_thread.start()
        logger.info(f"Proactive assistant started (check interval: {check_interval_s}s)")

    def stop(self) -> None:
        self._running = False
        self._save()

    def set_reminder_callback(self, callback: Callable[[str, str], None]) -> None:
        """Set callback for when a reminder fires: callback(title, message)."""
        self._on_reminder_callback = callback

    # ------------------------------------------------------------------
    # Recording actions
    # ------------------------------------------------------------------

    def record_action(self, user_input: str, action) -> None:
        """Record a user action to build routine and sequence patterns."""
        now = time.time()
        dt = datetime.now()
        action_name = getattr(action, "name", str(action))

        # Time-slot model (1-hour)
        hour_key = (dt.weekday(), dt.hour)
        self.routine_model[hour_key][action_name] += 1

        # Fine model (15-min)
        quarter = dt.minute // 15
        fine_key = (dt.weekday(), dt.hour, quarter)
        self.fine_model[fine_key][action_name] += 1

        # Day-type model
        if dt.weekday() < 5:
            self.weekday_model[dt.hour][action_name] += 1
        else:
            self.weekend_model[dt.hour][action_name] += 1

        # Sequence model
        if self._last_action:
            self.sequence_model[self._last_action][action_name] += 1
        self._last_action = action_name

        # Streak tracking
        date_str = dt.strftime("%Y-%m-%d")
        if action_name in self.streaks:
            streak_days, last_date = self.streaks[action_name]
            # Check if consecutive day
            try:
                last_dt = datetime.strptime(last_date, "%Y-%m-%d")
                if (dt.date() - last_dt.date()).days == 1:
                    self.streaks[action_name] = (streak_days + 1, date_str)
                elif (dt.date() - last_dt.date()).days > 1:
                    self.streaks[action_name] = (1, date_str)
                # Same day, no change (days == 0 falls through)
            except ValueError:
                self.streaks[action_name] = (1, date_str)
        else:
            self.streaks[action_name] = (1, date_str)

        # History
        self.action_history.append((now, action_name, user_input))

        # Periodically save
        if len(self.action_history) % 25 == 0:
            self._save()

    # ------------------------------------------------------------------
    # Suggestions
    # ------------------------------------------------------------------

    def get_suggestions(self, max_suggestions: int = 5) -> List[Dict[str, Any]]:
        """Get proactive suggestions for the current time using all models."""
        now = datetime.now()
        suggestions = []

        with self._model_lock:
            fine_routines = dict(self.fine_model.get((now.weekday(), now.hour, now.minute // 15), {}))
            hour_routines = dict(self.routine_model.get((now.weekday(), now.hour), {}))
            next_routines = dict(self.routine_model.get((now.weekday(), (now.hour + 1) % 24), {}))
            sequence_copy = dict(self.sequence_model)
            last_action = self._last_action

        # 1. Fine-grained time slot suggestions (15-min blocks)
        total_fine = sum(fine_routines.values()) if fine_routines else 1
        for action_name, count in sorted(fine_routines.items(), key=lambda x: -x[1]):
            confidence = _bayesian_confidence(count, total_fine)
            if confidence >= self.confidence_threshold:
                suggestions.append({
                    "action": action_name,
                    "confidence": round(confidence, 2),
                    "message": self._generate_suggestion_message(action_name, confidence),
                    "source": "fine_time",
                    "time_slot": f"{now.strftime('%A')} {now.hour:02d}:{quarter*15:02d}",
                })

        # 2. Hour-level suggestions
        total_hour = sum(hour_routines.values()) if hour_routines else 1
        for action_name, count in sorted(hour_routines.items(), key=lambda x: -x[1]):
            confidence = _bayesian_confidence(count, total_hour)
            if confidence >= self.confidence_threshold:
                # Avoid duplicates from fine model
                if not any(s["action"] == action_name for s in suggestions):
                    suggestions.append({
                        "action": action_name,
                        "confidence": round(confidence, 2),
                        "message": self._generate_suggestion_message(action_name, confidence),
                        "source": "hourly",
                        "time_slot": f"{now.strftime('%A')} at {now.hour:02d}:00",
                    })

        # 3. Sequence prediction (what typically follows my last action?)
        if last_action and last_action in sequence_copy:
            next_actions = sequence_copy[last_action]
            total_seq = sum(next_actions.values()) if next_actions else 1
            for action_name, count in sorted(next_actions.items(), key=lambda x: -x[1])[:3]:
                confidence = _bayesian_confidence(count, total_seq, prior_weight=2)
                if confidence >= 0.3:
                    suggestions.append({
                        "action": action_name,
                        "confidence": round(confidence, 2),
                        "message": f"After '{_action_label(last_action)}', you often do '{_action_label(action_name)}'",
                        "source": "sequence",
                    })

        # 4. Next hour suggestions
        total_next = sum(next_routines.values()) if next_routines else 1
        for action_name, count in sorted(next_routines.items(), key=lambda x: -x[1]):
            confidence = _bayesian_confidence(count, total_next)
            if confidence >= self.confidence_threshold:
                if not any(s["action"] == action_name and s.get("source") != "sequence"
                          for s in suggestions):
                    suggestions.append({
                        "action": action_name,
                        "confidence": round(confidence, 2),
                        "message": f"⏭ Up next: {self._generate_suggestion_message(action_name, confidence)}",
                        "source": "next_hour",
                        "time_slot": f"{now.strftime('%A')} at {(now.hour + 1) % 24:02d}:00",
                    })

        return sorted(suggestions, key=lambda s: -s["confidence"])[:max_suggestions]

    def get_todays_routine(self) -> List[Dict[str, Any]]:
        """Get the predicted routine for today using the best model."""
        today = datetime.now().weekday()
        routine = []

        for hour in range(24):
            # Prefer fine-grain then hourly
            hour_routines = self.routine_model.get((today, hour), {})
            total = sum(hour_routines.values()) if hour_routines else 1
            for action_name, count in sorted(hour_routines.items(), key=lambda x: -x[1]):
                confidence = _bayesian_confidence(count, total)
                if confidence >= 0.2:  # Relaxed threshold for daily view
                    # Check streak
                    streak_info = ""
                    if action_name in self.streaks:
                        streak_days, _ = self.streaks[action_name]
                        if streak_days >= 3:
                            streak_info = f" (🔥 {streak_days}-day streak)"

                    routine.append({
                        "hour": hour,
                        "action": action_name,
                        "confidence": round(confidence, 2),
                        "count": count,
                        "streak": streak_info if streak_info else None,
                    })

        return sorted(routine, key=lambda x: (x["hour"], -x["confidence"]))

    def get_proactive_reminder(self) -> Optional[Dict[str, Any]]:
        """Return the strongest proactive reminder if one is due now."""
        suggestions = self.get_suggestions(max_suggestions=3)
        if suggestions:
            top = suggestions[0]
            if top["confidence"] >= self.suggestion_high_confidence:
                return top
        return None

    def predict_next_action(self) -> Optional[Dict[str, Any]]:
        """Predict the user's next most likely action using sequence + time models."""
        now = datetime.now()
        candidates: Dict[str, float] = defaultdict(float)

        # Sequence model (weight: 0.6)
        if self._last_action and self._last_action in self.sequence_model:
            next_actions = self.sequence_model[self._last_action]
            total = sum(next_actions.values()) if next_actions else 1
            for action, count in next_actions.items():
                candidates[action] += 0.6 * (count / total)

        # Time model (weight: 0.4)
        fine_key = (now.weekday(), now.hour, now.minute // 15)
        fine_routines = self.fine_model.get(fine_key, {})
        total_fine = sum(fine_routines.values()) if fine_routines else 1
        for action, count in fine_routines.items():
            candidates[action] += 0.4 * (count / total_fine)

        if not candidates:
            return None

        best_action = max(candidates, key=candidates.get)
        confidence = candidates[best_action]

        if confidence >= 0.2:
            return {
                "action": best_action,
                "confidence": round(confidence, 2),
                "label": _action_label(best_action),
            }
        return None

    # ------------------------------------------------------------------
    # Streak & pattern insights
    # ------------------------------------------------------------------

    def get_streaks(self) -> List[Dict[str, Any]]:
        """Get current action streaks."""
        return [
            {"action": action, "label": _action_label(action),
             "streak_days": days, "last_date": date}
            for action, (days, date) in sorted(
                self.streaks.items(), key=lambda x: -x[1][0]
            )
            if days >= 2
        ]

    def get_insights(self) -> List[str]:
        """Generate human-readable insights from learned patterns."""
        insights = []
        streaks = self.get_streaks()
        for s in streaks[:5]:
            if s["streak_days"] >= 7:
                insights.append(
                    f"You've done '{s['label']}' for {s['streak_days']} days straight — "
                    f"this is a strong routine!"
                )
            elif s["streak_days"] >= 3:
                insights.append(
                    f"You're on a {s['streak_days']}-day streak with '{s['label']}'"
                )

        # Top time-slot pattern
        now = datetime.now()
        hour_routines = self.routine_model.get((now.weekday(), now.hour), {})
        if hour_routines:
            top = max(hour_routines, key=hour_routines.get)
            count = hour_routines[top]
            if count >= 3:
                insights.append(
                    f"At this hour, you most frequently: {_action_label(top)}"
                )

        return insights

    # ------------------------------------------------------------------
    # Notification system
    # ------------------------------------------------------------------

    def _reminder_loop(self, interval_s: int) -> None:
        """Background thread that checks for reminders and sends notifications."""
        while self._running:
            try:
                time.sleep(interval_s)
                self._check_and_notify()
            except Exception as e:
                logger.warning(f"Reminder loop error: {e}")

    def _check_and_notify(self) -> None:
        """Check if a high-confidence reminder is due and send notification."""
        reminder = self.get_proactive_reminder()
        if not reminder:
            return

        action = reminder.get("action", "")
        message = reminder.get("message", "")

        # Rate limit: don't spam the same reminder
        now = time.time()
        last = self._last_notify_time.get(action, 0)
        if now - last < self.max_notify_frequency:
            return

        self._last_notify_time[action] = now
        title = "Nexus Reminder"
        self._send_notification(title, message)

        # Record
        with self._notification_lock:
            self.notifications.append({
                "timestamp": now,
                "action": action,
                "message": message,
                "confidence": reminder.get("confidence", 0),
            })
            # Keep last 100
            if len(self.notifications) > 100:
                self.notifications = self.notifications[-100:]

        # Fire callback
        if self._on_reminder_callback:
            try:
                self._on_reminder_callback(title, message)
            except Exception as e:
                logger.warning(f"Reminder callback failed: {e}")

    def _send_notification(self, title: str, message: str) -> bool:
        """Send a desktop notification. Returns True if sent."""
        system = platform.system()
        try:
            if system == "Linux":
                subprocess.run(
                    ["notify-send", title, message, "--icon=nexus"],
                    timeout=3, capture_output=True,
                )
                return True
            elif system == "Darwin":
                subprocess.run(
                    ["osascript", "-e",
                     f'display notification "{message}" with title "{title}"'],
                    timeout=3, capture_output=True,
                )
                return True
            elif system == "Windows":
                # Windows toast notification via PowerShell
                subprocess.run(
                    ["powershell", "-Command",
                     f"New-BurntToastNotification -Text '{title}', '{message}'"],
                    timeout=3, capture_output=True,
                )
                return True
        except Exception as e:
            logger.debug(f"Notification failed: {e}")

        # Fallback: just log it
        logger.info(f"📢 Reminder: [{title}] {message}")
        return False

    def get_notifications(self, limit: int = 20) -> List[Dict[str, Any]]:
        with self._notification_lock:
            return list(reversed(self.notifications[-limit:]))

    def dismiss_notification(self, index: int) -> bool:
        with self._notification_lock:
            if 0 <= index < len(self.notifications):
                self.notifications[index]["dismissed"] = True
                return True
        return False

    def send_test_notification(self) -> bool:
        """Send a test notification to verify the notification system works."""
        return self._send_notification("Nexus", "This is a test reminder from Nexus!")

    # ------------------------------------------------------------------
    # Persistence
    # ------------------------------------------------------------------

    def _save(self) -> None:
        try:
            data = {
                "routines": {
                    f"{d}_{h}": dict(actions)
                    for (d, h), actions in self.routine_model.items()
                },
                "fine_model": {
                    f"{d}_{h}_{q}": dict(actions)
                    for (d, h, q), actions in self.fine_model.items()
                    if sum(actions.values()) >= 3  # Only save meaningful slots
                },
                "sequence_model": {
                    prev: dict(nexts)
                    for prev, nexts in self.sequence_model.items()
                },
                "streaks": {
                    action: [days, date]
                    for action, (days, date) in self.streaks.items()
                },
                "weekday_model": {
                    str(h): dict(actions)
                    for h, actions in self.weekday_model.items()
                },
                "weekend_model": {
                    str(h): dict(actions)
                    for h, actions in self.weekend_model.items()
                },
                "history_count": len(self.action_history),
                "last_action": self._last_action,
            }
            with open(self.routine_file, "w", encoding="utf-8") as f:
                json.dump(data, f, indent=2)
        except Exception as e:
            logger.warning(f"Failed to save routines: {e}")

    def _load(self) -> None:
        if not os.path.exists(self.routine_file):
            return
        try:
            with open(self.routine_file, "r", encoding="utf-8") as f:
                data = json.load(f)

            for key, actions in data.get("routines", {}).items():
                parts = key.split("_")
                if len(parts) == 2:
                    self.routine_model[(int(parts[0]), int(parts[1]))] = defaultdict(int, actions)

            for key, actions in data.get("fine_model", {}).items():
                parts = key.split("_")
                if len(parts) == 3:
                    self.fine_model[(int(parts[0]), int(parts[1]), int(parts[2]))] = defaultdict(int, actions)

            for prev, nexts in data.get("sequence_model", {}).items():
                self.sequence_model[prev] = defaultdict(int, nexts)

            for action, (days, date) in data.get("streaks", {}).items():
                self.streaks[action] = (days, date)

            for h_str, actions in data.get("weekday_model", {}).items():
                self.weekday_model[int(h_str)] = defaultdict(int, actions)

            for h_str, actions in data.get("weekend_model", {}).items():
                self.weekend_model[int(h_str)] = defaultdict(int, actions)

            self._last_action = data.get("last_action")

            logger.info(
                f"Loaded routines: {len(self.routine_model)} hour-slots, "
                f"{len(self.fine_model)} fine-slots, "
                f"{len(self.sequence_model)} sequences"
            )
        except Exception as e:
            logger.warning(f"Failed to load routines: {e}")


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _bayesian_confidence(count: int, total: int, prior_weight: int = 5) -> float:
    """Bayesian confidence with Laplace smoothing.

    Smooths small-sample estimates toward 0.5, making confidence scores
    more reliable when there's little data.
    """
    if total == 0:
        return 0.0
    return (count + prior_weight * 0.5) / (total + prior_weight)


def _action_label(action_name: str) -> str:
    """Convert an action name to a human-readable label."""
    labels = {
        "GET_TIME_DATE": "check the time",
        "GET_WEATHER": "check the weather",
        "GET_JOKE": "ask for a joke",
        "SET_ALARM": "set an alarm",
        "SET_TIMER": "set a timer",
        "TAKE_NOTE": "take a note",
        "SET_REMINDER": "set a reminder",
        "PLAY_MEDIA": "play music",
        "NAVIGATE": "navigate somewhere",
        "WEB_SEARCH": "search the web",
        "OPEN_WEBSITE": "open a website",
        "OPEN_APP": "open an app",
        "CALCULATE": "do a calculation",
        "ROLL_DICE": "roll dice",
        "FLIP_COIN": "flip a coin",
        "SET_VOLUME": "adjust volume",
        "MEDIA_CONTROL": "control media",
    }
    return labels.get(action_name, action_name.replace("_", " ").lower())
