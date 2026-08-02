# Security - Input Sanitization & Threat Detection
#
# Ported from the existing security_guard.py.
# Provides: input sanitization, prompt injection detection, threat scoring.

from __future__ import annotations

import re
from typing import ClassVar, List, Optional

from nexus_server.models import SanitizedInput, ThreatLevel


class SecurityGuard:
    _instance: ClassVar[Optional["SecurityGuard"]] = None

    def __new__(cls) -> "SecurityGuard":
        if cls._instance is None:
            cls._instance = super().__new__(cls)
            cls._instance._initialized = False
        return cls._instance

    def __init__(self) -> None:
        if self._initialized:
            return
        self._initialized = True
        self._forbidden_tokens = [
            "ignore previous", "ignore the above", "disregard",
            "override instructions", "system prompt",
            "you are now", "pretend you are", "act as a",
            "jailbreak", "developer mode",
            "<script", "</script>", "javascript:",
            "onerror=", "onload=",
            "rm -rf", "sudo ", "chmod ",
        ]
        self._dangerous_patterns = [
            r"\b(?:ignore|disregard|override).{0,40}(?:instructions?|prompt)",
            r"\b(?:you are|pretend|act as).{0,30}(?:admin|root|developer)",
            r"<[^>]+(?:on\w+\s*=|javascript:)",
            r"\b(?:drop|delete|truncate)\s+(?:table|database)",
        ]
        self._compiled = [
            (p, re.compile(p, re.IGNORECASE))
            for p in self._dangerous_patterns
        ]
        self._max_length = 500
        self._control_re = re.compile(r"[\u0000-\u001F\x7F]")

    def scan(self, input_text: str) -> SanitizedInput:
        trimmed = input_text.strip()[:self._max_length]
        if not trimmed:
            return SanitizedInput(trimmed, trimmed, trimmed, ThreatLevel.SAFE, False)

        lowered = trimmed.lower()
        for token in self._forbidden_tokens:
            if token.lower() in lowered:
                return SanitizedInput(
                    trimmed, "", "", ThreatLevel.DANGEROUS, True,
                    f"Forbidden token: {token}",
                )

        hits = sum(1 for _, c in self._compiled if c.search(trimmed))
        if hits == 0:
            threat = ThreatLevel.SAFE
        elif hits <= 2:
            threat = ThreatLevel.SUSPICIOUS
        else:
            threat = ThreatLevel.DANGEROUS

        sanitized = self._remove_controls(trimmed)
        if threat == ThreatLevel.DANGEROUS:
            return SanitizedInput(trimmed, sanitized, "", threat, True,
                                 "Input contains dangerous patterns.")

        return SanitizedInput(trimmed, sanitized, sanitized, threat, False)

    def is_safe(self, input_text: str) -> bool:
        result = self.scan(input_text)
        return result.threat_level == ThreatLevel.SAFE and not result.rejected

    def _remove_controls(self, value: str) -> str:
        return self._control_re.sub("", value).strip()

    def get_alerts(self) -> list:
        return []  # Simple implementation; extended in Rust layer
