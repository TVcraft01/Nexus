package com.nexus.app.security

import android.util.Log
import androidx.annotation.Keep
import java.util.regex.PatternSyntaxException

@Keep
class SecurityGuard private constructor() {

    data class SanitizedInput(
        val original: String,
        val sanitized: String,
        val commandString: String,
        val threatLevel: ThreatLevel,
        val rejected: Boolean,
        val reason: String = ""
    )

    companion object {
        @Volatile
        private var INSTANCE: SecurityGuard? = null

        fun getInstance(): SecurityGuard {
            return INSTANCE ?: synchronized(this) {
                INSTANCE ?: SecurityGuard().also { INSTANCE = it }
            }
        }
    }

    private val forbiddenTokens = setOf(
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
        "\${",
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
        "--no-sandbox"
    )

    private val dangerousPatterns = listOf(
        Regex("\\b(?:ignore|disregard|override).{0,40}(?:instructions?|prompt|command)", RegexOption.IGNORE_CASE),
        Regex("\\b(?:you are|pretend|act as).{0,30}(?:admin|root|developer|ai|assistant)", RegexOption.IGNORE_CASE),
        Regex("<[^>]+(?:on\\w+\\s*=|javascript:)", RegexOption.IGNORE_CASE),
        Regex("\\$\\{[^}]*\\}"),
        Regex("\\b(?:drop|delete|truncate|insert|update|select).{0,30}(?:table|database|from|into)", RegexOption.IGNORE_CASE),
        Regex("(?:\\b(?:https?|ftp)://)[^\\s]+")
    )

    private val maxLength = 500
    private val urlPattern = Regex("(?:https?|ftp)://[^\\s]+")

    fun scan(input: String): SanitizedInput {
        val trimmed = input.trim().take(maxLength)
        if (trimmed.isBlank()) {
            return SanitizedInput(trimmed, trimmed, trimmed, ThreatLevel.SAFE, false)
        }

        val lowered = trimmed.lowercase()

        forbiddenTokens.forEach { token ->
            if (lowered.contains(token.lowercase())) {
                return SanitizedInput(
                    trimmed,
                    "",
                    "",
                    ThreatLevel.DANGEROUS,
                    true,
                    "Forbidden token detected: $token"
                )
            }
        }

        var suspiciousHits = 0
        dangerousPatterns.forEach { pattern ->
            try {
                if (pattern.containsMatchIn(trimmed)) {
                    suspiciousHits++
                }
            } catch (_: PatternSyntaxException) {
                // ignore malformed patterns
            }
        }

        if (trimmed.length > 300) suspiciousHits++
        if (urlPattern.containsMatchIn(trimmed)) suspiciousHits++

        val threatLevel = when {
            suspiciousHits == 0 -> ThreatLevel.SAFE
            suspiciousHits <= 2 -> ThreatLevel.SUSPICIOUS
            else -> ThreatLevel.DANGEROUS
        }

        val sanitized = when (threatLevel) {
            ThreatLevel.SAFE -> removeControlChars(trimmed)
            else -> sanitizeString(trimmed)
        }

        val commandString = removeControlChars(trimmed)

        if (threatLevel == ThreatLevel.DANGEROUS) {
            return SanitizedInput(
                trimmed,
                sanitized,
                "",
                threatLevel,
                true,
                "Input contains dangerous patterns and has been rejected."
            )
        }

        return SanitizedInput(trimmed, sanitized, commandString, threatLevel, false)
    }

    fun isSafe(input: String): Boolean {
        val result = scan(input)
        return result.threatLevel == ThreatLevel.SAFE && !result.rejected
    }

    private fun removeControlChars(input: String): String {
        return input.replace(Regex("[\u0000-\u001F\\x7F]"), "").trim()
    }

    private fun sanitizeString(input: String): String {
        return input
            .replace(Regex("[\u0000-\u001F\\x7F]"), "")
            .replace("<", "&lt;")
            .replace(">", "&gt;")
            .replace("\"", "&quot;")
            .replace("'", "&#x27;")
            .trim()
    }
}
