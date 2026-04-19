"""Pomodoro timer. No AI, no network."""
import re
import threading
import time

NAME = "Pomodoro"
DESCRIPTION = "Pomodoro work sessions with automatic break reminders."
CAPABILITIES = ["notifications"]
PATTERNS = [
    r"(pomodoro|pomo)",
    r"(work session|session de travail|focus (session|mode|timer))",
    r"(start|begin|lance[rz]?).{0,15}(focus|work|pomodoro|travail)",
    r"(25 min.{0,10}(timer|break|pause|work))",
]

_active: dict = {}


def handle(text, lower, language, memory=None):
    fr = language.startswith("fr")

    # Stop
    if re.search(r"(stop|cancel|annule|end|finish).{0,15}(pomodoro|pomo|focus|session)", lower):
        if _active:
            for t in _active.values():
                t.cancel()
            _active.clear()
            return {"response": "Session stopped." if not fr else "Session arrêtée.", "intent": "pomodoro"}
        return {"response": "No active session." if not fr else "Aucune session active.", "intent": "pomodoro"}

    # Status
    if re.search(r"(status|how long|combien de temps).{0,15}(pomodoro|session|focus)", lower):
        if _active.get("start"):
            elapsed = int(time.time() - _active["start"])
            m, s = divmod(elapsed, 60)
            return {"response": f"Session in progress: {m}m {s}s" if not fr
                    else f"Session en cours : {m}m {s}s", "intent": "pomodoro"}
        return {"response": "No active session." if not fr else "Aucune session active.", "intent": "pomodoro"}

    # Custom duration
    dur_match = re.search(r"(\d+)\s*(min|minute)", lower)
    work_mins = int(dur_match.group(1)) if dur_match else 25
    work_mins = max(1, min(work_mins, 120))
    break_mins = 5 if work_mins <= 25 else 10

    if _active:
        for t in _active.values():
            try: t.cancel()
            except Exception: pass
        _active.clear()

    _active["start"] = time.time()

    def _work_done():
        print(f"[POMODORO] Work session done ({work_mins}min). Take a {break_mins}min break.")
        _active.pop("work", None)

    def _break_done():
        print(f"[POMODORO] Break done ({break_mins}min). Ready for the next session.")
        _active.clear()

    t_work = threading.Timer(work_mins * 60, _work_done)
    t_break = threading.Timer((work_mins + break_mins) * 60, _break_done)
    t_work.daemon = True
    t_break.daemon = True
    t_work.start()
    t_break.start()
    _active["work"] = t_work
    _active["break"] = t_break

    return {"response": (f"{work_mins}-minute focus session started. Break in {work_mins} minutes." if not fr
                          else f"Session de {work_mins} minutes lancée. Pause dans {work_mins} minutes."),
            "intent": "pomodoro"}
