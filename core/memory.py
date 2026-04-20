"""
Nexus Memory System
===================
Three tiers: core (forever), long (fades if unused), working (session only).
"""
import json, os
from datetime import datetime

DATA_DIR  = os.path.join(os.path.dirname(__file__), "data")
CORE_FILE = os.path.join(DATA_DIR, "core_memory.json")
LONG_FILE = os.path.join(DATA_DIR, "long_memory.json")

class Memory:
    def __init__(self):
        os.makedirs(DATA_DIR, exist_ok=True)
        self.core    = self._load(CORE_FILE)
        self.long    = self._load(LONG_FILE) or {"facts": []}
        self.working = []

    def _load(self, path):
        if os.path.exists(path):
            with open(path) as f: return json.load(f)
        return {}

    def _save_long(self):
        with open(LONG_FILE, "w") as f:
            json.dump(self.long, f, indent=2)

    def remember(self, fact: str, permanent=False):
        self.long["facts"].append({
            "fact": fact,
            "timestamp": datetime.now().isoformat(),
            "access_count": 0,
            "permanent": permanent
        })
        self._save_long()

    def get_context(self):
        return {
            "name":         self.core.get("name", "user"),
            "language":     self.core.get("language", "en"),
            "recent_facts": [f["fact"] for f in self.long.get("facts", [])[-20:]]
        }

    def add_working(self, role: str, content: str):
        self.working.append({"role": role, "content": content})

    def clear_working(self):
        self.working = []
