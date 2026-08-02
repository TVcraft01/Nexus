package com.nexus.app.skill

import androidx.annotation.Keep

/**
 * A downloadable skill package that extends Nexus's command knowledge.
 * Skills are JSON files hosted on GitHub repos that define:
 * - Command patterns (regex → action mappings)
 * - Voice grammar entries (what phrases to recognize)
 * - Action handlers (how to execute each command)
 *
 * Skills are versioned and can be updated independently of the app.
 * The app ships with zero built-in commands — everything comes from skills.
 */
@Keep
data class SkillManifest(
    /** Unique skill identifier (e.g. "com.nexus.media", "com.nexus.home") */
    val id: String,
    /** Human-readable name */
    val name: String,
    /** Semantic version (e.g. "1.2.0") */
    val version: String,
    /** Brief description of what this skill does */
    val description: String = "",
    /** Author name or handle */
    val author: String = "",
    /** GitHub repo to fetch updates from (e.g. "user/repo") */
    val repo: String? = null,
    /** Minimum app version required to use this skill */
    val minAppVersion: String = "1.0.0",
    /** Command definitions provided by this skill */
    val commands: List<SkillCommand> = emptyList(),
    /** Voice grammar entries — phrases the recognizer should listen for */
    val grammar: List<String> = emptyList(),
    /** Dependencies on other skills (skill IDs) */
    val dependencies: List<String> = emptyList(),
    /** When this skill was last updated */
    val updatedAt: Long = System.currentTimeMillis()
)

/**
 * A single command definition within a skill.
 */
@Keep
data class SkillCommand(
    /** Human-readable name (e.g. "Play Media") */
    val name: String,
    /** Action type identifier (e.g. "PLAY_MEDIA", "SET_ALARM") */
    val actionType: String,
    /** Regex pattern to match user input */
    val pattern: String,
    /** Default payload template (supports capture groups like $1, $2) */
    val payloadTemplate: String = "",
    /** Example phrases that should trigger this command */
    val examples: List<String> = emptyList(),
    /** Whether this command requires specific permissions */
    val permissions: List<String> = emptyList()
)

/**
 * Installed skill with local metadata.
 */
@Keep
data class InstalledSkill(
    val manifest: SkillManifest,
    /** Whether this skill is currently enabled */
    val enabled: Boolean = true,
    /** When it was installed locally */
    val installedAt: Long = System.currentTimeMillis(),
    /** Path to the local skill file */
    val localPath: String = ""
)
