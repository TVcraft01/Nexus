"""Port of Android SecurityGuard for input sanitization."""

from __future__ import annotations

from typing import ClassVar, List, Optional

from .models import SanitizedInput, ThreatLevel


class SecurityGuard:
    _instance: ClassVar[Optional["SecurityGuard"]] = None
    _initialized: bool = False

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
            "ignore previous",
            "ignore the above",
            "disregard",
            "override instructions",
            "system prompt",
            "you are now",
            "pretend you are",
            "act as a",
            "jailbreak",
            "dar mode",
            "developer mode",
            "ignore safety",
            "new instruction",
            "leak",
            "reveal prompt",
            "<script",
            "</script>",
            "javascript:",
            "onerror=",
            "onload=",
            "{{",
            "{%",
            "${",
            "<%",
            "<?php",
            "exec(",
            "eval(",
            "system(",
            "rm -rf",
            "sudo ",
            "chmod ",
            "wget ",
            "curl ",
            "--disable",
            "--no-sandbox",
        ]
        self._dangerous_patterns = [
            "\\b(?:ignore|disregard|override).{0,40}(?:instructions?|prompt|command)",
            "\\b(?:you are|pretend|act as).{0,30}(?:admin|root|developer|ai|assistant)",
            "<[^>]+(?:on\\w+\\s*=|javascript:)",
            "\\$\\{[^}]*\\}",
            "\\b(?:drop|delete|truncate|insert|update|select).{0,30}(?:table|database|from|into)",
            "(?:\\b(?:https?|ftp)://)[^\\s]+",
        ]
        self._compiled_patterns = [
            (pattern, __import__("re").compile(pattern, __import__("re").IGNORECASE))
            for pattern in self._dangerous_patterns
        ]
        self._max_length = 500
        self._control_regex = __import__("re").compile("[\u0000-\u001F\\x7F]")
        self._url_pattern = __import__("re").compile("(?:https?|ftp)://[^\\s]+")

    def scan(self, input: str) -> SanitizedInput:
        trimmed = input.strip()[: self._max_length]
        if not trimmed:
            return SanitizedInput(trimmed, trimmed, trimmed, ThreatLevel.SAFE, False)

        lowered = trimmed.lower()
        for token in self._forbidden_tokens:
            if token.lower() in lowered:
                return SanitizedInput(
                    trimmed,
                    "",
                    "",
                    ThreatLevel.DANGEROUS,
                    True,
                    f"Forbidden token detected: {token}",
                )

        suspicious_hits = 0
        for _, compiled in self._compiled_patterns:
            if compiled.search(trimmed):
                suspicious_hits += 1

        if len(trimmed) > 300:
            suspicious_hits += 1
        if self._url_pattern.search(trimmed):
            suspicious_hits += 1

        if suspicious_hits == 0:
            threat = ThreatLevel.SAFE
        elif suspicious_hits <= 2:
            threat = ThreatLevel.SUSPICIOUS
        else:
            threat = ThreatLevel.DANGEROUS

        if threat == ThreatLevel.SAFE:
            sanitized = self._remove_control_chars(trimmed)
        else:
            sanitized = self._sanitize_string(trimmed)

        command_string = self._remove_control_chars(trimmed)

        if threat == ThreatLevel.DANGEROUS:
            return SanitizedInput(
                trimmed,
                sanitized,
                "",
                threat,
                True,
                "Input contains dangerous patterns and has been rejected.",
            )

        return SanitizedInput(trimmed, sanitized, command_string, threat, False)

    def is_safe(self, input: str) -> bool:
        result = self.scan(input)
        return result.threat_level == ThreatLevel.SAFE and not result.rejected

    def _remove_control_chars(self, value: str) -> str:
        return self._control_regex.sub("", value).strip()

    def _sanitize_string(self, value: str) -> str:
        return (
            self._control_regex.sub("", value)
            .replace("<", "&lt;")
            .replace(">", "&gt;")
            .replace('"', "&quot;")
            .replace("'", "&#x27;")
            .strip()
        )
