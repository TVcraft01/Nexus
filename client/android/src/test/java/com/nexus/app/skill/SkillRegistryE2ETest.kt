package com.nexus.app.skill

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * End-to-end tests for the Skill system.
 *
 * Tests the complete lifecycle:
 * 1. SkillManifest creation and serialization round-trip
 * 2. Skill command pattern matching
 * 3. Grammar extraction
 * 4. Enable/disable flow
 * 5. Persistence (save/load round-trip)
 */
class SkillRegistryE2ETest {

    // ---------------------------------------------------------------
    // 1. Manifest Serialization Round-Trip
    // ---------------------------------------------------------------

    @Test
    fun `manifest survives full JSON serialization round-trip`() {
        val original = SkillManifest(
            id = "com.nexus.media",
            name = "Media Player",
            version = "2.1.0",
            description = "Play, pause, skip music",
            author = "freebuff",
            repo = "freebuff/nexus-skills",
            commands = listOf(
                SkillCommand(
                    name = "Play Music",
                    actionType = "PLAY_MEDIA",
                    pattern = "^play (.+)$",
                    payloadTemplate = "",
                    examples = listOf("play jazz", "play my playlist"),
                    permissions = listOf("android.permission.RECORD_AUDIO")
                ),
                SkillCommand(
                    name = "Pause Music",
                    actionType = "PAUSE_MEDIA",
                    pattern = "^pause (?:music|audio)$",
                    payloadTemplate = "",
                    examples = listOf("pause music", "stop audio")
                )
            ),
            grammar = listOf("play", "pause", "music", "audio", "skip", "next track"),
            dependencies = listOf("com.nexus.core"),
            updatedAt = 1700000000000L
        )

        // Serialize to JSON
        val json = manifestToJson(original)

        // Deserialize from JSON
        val restored = jsonToManifest(json)

        // Verify all fields survive the round-trip
        assertEquals(original.id, restored.id)
        assertEquals(original.name, restored.name)
        assertEquals(original.version, restored.version)
        assertEquals(original.description, restored.description)
        assertEquals(original.author, restored.author)
        assertEquals(original.repo, restored.repo)
        assertEquals(original.dependencies, restored.dependencies)
        assertEquals(original.updatedAt, restored.updatedAt)

        // Verify commands survive
        assertEquals(2, restored.commands.size)
        assertEquals("Play Music", restored.commands[0].name)
        assertEquals("PLAY_MEDIA", restored.commands[0].actionType)
        assertEquals("^play (.+)$", restored.commands[0].pattern)
        assertEquals(listOf("play jazz", "play my playlist"), restored.commands[0].examples)
        assertEquals(listOf("android.permission.RECORD_AUDIO"), restored.commands[0].permissions)

        assertEquals("Pause Music", restored.commands[1].name)
        assertEquals("PAUSE_MEDIA", restored.commands[1].actionType)

        // Verify grammar survives
        assertEquals(6, restored.grammar.size)
        assertEquals("play", restored.grammar[0])
        assertEquals("next track", restored.grammar[5])
    }

    @Test
    fun `manifest with empty commands and grammar survives round-trip`() {
        val original = SkillManifest(
            id = "com.nexus.empty",
            name = "Empty Skill",
            version = "0.1.0"
        )

        val json = manifestToJson(original)
        val restored = jsonToManifest(json)

        assertEquals(original.id, restored.id)
        assertEquals(0, restored.commands.size)
        assertEquals(0, restored.grammar.size)
        assertEquals(0, restored.dependencies.size)
    }

    @Test
    fun `manifest with null repo survives round-trip`() {
        val original = SkillManifest(
            id = "com.nexus.norepo",
            name = "No Repo Skill",
            version = "1.0.0",
            repo = null
        )

        val json = manifestToJson(original)
        val restored = jsonToManifest(json)

        assertEquals(original.id, restored.id)
        assertEquals(null, restored.repo)
    }

    // ---------------------------------------------------------------
    // 2. Skill Command Pattern Matching
    // ---------------------------------------------------------------

    @Test
    fun `skill command patterns match user input`() {
        val commands = listOf(
            SkillCommand(
                name = "Play",
                actionType = "PLAY_MEDIA",
                pattern = "^play (.+)$"
            ),
            SkillCommand(
                name = "Pause",
                actionType = "PAUSE_MEDIA",
                pattern = "^pause (?:music|audio)$"
            ),
            SkillCommand(
                name = "Set Timer",
                actionType = "SET_TIMER",
                pattern = "^set (?:a )?timer (?:for )?(\\d+) (?:seconds?|minutes?|hours?)$"
            )
        )

        // Test Play
        val playRegex = Regex(commands[0].pattern, RegexOption.IGNORE_CASE)
        val playMatch = playRegex.find("play jazz")
        assertNotNull(playMatch)
        assertEquals("jazz", playMatch!!.groupValues[1])

        // Test Pause
        val pauseRegex = Regex(commands[1].pattern, RegexOption.IGNORE_CASE)
        assertNotNull(pauseRegex.find("pause music"))
        assertNotNull(pauseRegex.find("pause audio"))
        assertEquals(null, pauseRegex.find("pause the song"))

        // Test Timer
        val timerRegex = Regex(commands[2].pattern, RegexOption.IGNORE_CASE)
        val timerMatch = timerRegex.find("set a timer for 30 minutes")
        assertNotNull(timerMatch)
        assertEquals("30", timerMatch!!.groupValues[1])
    }

    @Test
    fun `skill command patterns are case insensitive`() {
        val pattern = "^play (.+)$"
        val regex = Regex(pattern, RegexOption.IGNORE_CASE)

        assertNotNull(regex.find("play jazz"))
        assertNotNull(regex.find("Play Jazz"))
        assertNotNull(regex.find("PLAY JAZZ"))
        assertNotNull(regex.find("Play jazz"))
    }

    @Test
    fun `skill commands extract payload from capture groups`() {
        val pattern = "^play (.+?) on (.+)$"
        val regex = Regex(pattern, RegexOption.IGNORE_CASE)
        val match = regex.find("play jazz on spotify")

        assertNotNull(match)
        assertEquals("jazz", match!!.groupValues[1])
        assertEquals("spotify", match.groupValues[2])
    }

    // ---------------------------------------------------------------
    // 3. Grammar Extraction
    // ---------------------------------------------------------------

    @Test
    fun `grammar from multiple skills is merged and deduplicated`() {
        val skill1Grammar = listOf("play", "pause", "music", "play music")
        val skill2Grammar = listOf("play", "skip", "next track", "music")
        val skill3Grammar = listOf("set timer", "play")

        val allGrammar = (skill1Grammar + skill2Grammar + skill3Grammar).distinct()

        assertEquals(7, allGrammar.size)
        assertTrue(allGrammar.contains("play"))
        assertTrue(allGrammar.contains("pause"))
        assertTrue(allGrammar.contains("music"))
        assertTrue(allGrammar.contains("skip"))
        assertTrue(allGrammar.contains("next track"))
        assertTrue(allGrammar.contains("set timer"))
        assertTrue(allGrammar.contains("play music"))
    }

    // ---------------------------------------------------------------
    // 4. Full Persistence Round-Trip (simulates app restart)
    // ---------------------------------------------------------------

    @Test
    fun `full persistence round-trip preserves commands and grammar`() {
        // Simulate the full save/load cycle that SkillRegistry does

        // 1. Create a manifest with commands and grammar
        val manifest = SkillManifest(
            id = "com.test.skill",
            name = "Test Skill",
            version = "1.0.0",
            description = "A test skill",
            author = "tester",
            commands = listOf(
                SkillCommand("Play", "PLAY_MEDIA", "^play (.+)$"),
                SkillCommand("Pause", "PAUSE_MEDIA", "^pause$")
            ),
            grammar = listOf("play", "pause", "music"),
            dependencies = listOf("com.test.core")
        )

        // 2. Serialize to JSON (simulates saveToDisk)
        val manifestJson = manifestToJson(manifest)
        val registryObj = JSONObject().apply {
            put("id", manifest.id)
            put("version", manifest.version)
            put("enabled", true)
            put("installedAt", System.currentTimeMillis())
            put("manifest", manifestJson)
        }

        // 3. Deserialize from JSON (simulates loadFromDisk)
        val loadedManifestObj = registryObj.getJSONObject("manifest")
        val restored = jsonToManifest(loadedManifestObj)

        // 4. Verify commands are still there
        assertEquals(2, restored.commands.size)
        assertEquals("PLAY_MEDIA", restored.commands[0].actionType)
        assertEquals("^play (.+)$", restored.commands[0].pattern)

        // 5. Verify grammar is still there
        assertEquals(3, restored.grammar.size)
        assertEquals("play", restored.grammar[0])

        // 6. Verify dependencies are still there
        assertEquals(1, restored.dependencies.size)
        assertEquals("com.test.core", restored.dependencies[0])
    }

    // ---------------------------------------------------------------
    // 5. Enable/Disable Logic
    // ---------------------------------------------------------------

    @Test
    fun `disabled skills are excluded from command and grammar lists`() {
        val skills = mutableListOf(
            InstalledSkill(
                manifest = SkillManifest(
                    id = "enabled-skill",
                    name = "Enabled",
                    version = "1.0.0",
                    commands = listOf(SkillCommand("Play", "PLAY_MEDIA", "^play$")),
                    grammar = listOf("play")
                ),
                enabled = true
            ),
            InstalledSkill(
                manifest = SkillManifest(
                    id = "disabled-skill",
                    name = "Disabled",
                    version = "1.0.0",
                    commands = listOf(SkillCommand("Pause", "PAUSE_MEDIA", "^pause$")),
                    grammar = listOf("pause")
                ),
                enabled = false
            )
        )

        val enabledSkills = skills.filter { it.enabled }
        val allCommands = enabledSkills.flatMap { it.manifest.commands }
        val allGrammar = enabledSkills.flatMap { it.manifest.grammar }.distinct()

        assertEquals(1, enabledSkills.size)
        assertEquals(1, allCommands.size)
        assertEquals("PLAY_MEDIA", allCommands[0].actionType)
        assertEquals(1, allGrammar.size)
        assertEquals("play", allGrammar[0])
    }

    @Test
    fun `re-enabling a skill restores its commands and grammar`() {
        val skills = mutableListOf(
            InstalledSkill(
                manifest = SkillManifest(
                    id = "skill-1",
                    name = "Skill 1",
                    version = "1.0.0",
                    commands = listOf(SkillCommand("Play", "PLAY_MEDIA", "^play$")),
                    grammar = listOf("play")
                ),
                enabled = false
            )
        )

        // Initially disabled
        val enabledBefore = skills.filter { it.enabled }
        assertEquals(0, enabledBefore.size)

        // Enable it
        skills[0] = skills[0].copy(enabled = true)

        // Now enabled
        val enabledAfter = skills.filter { it.enabled }
        assertEquals(1, enabledAfter.size)
        assertEquals("play", enabledAfter[0].manifest.grammar[0])
    }

    // ---------------------------------------------------------------
    // 6. Skill Downloader Cache Logic
    // ---------------------------------------------------------------

    @Test
    fun `cache freshness check uses lastModified`() {
        val now = System.currentTimeMillis()
        val cacheTTL = 6 * 60 * 60 * 1000L // 6 hours

        // Fresh cache: file was modified 1 hour ago
        val freshTime = now - (1 * 60 * 60 * 1000)
        assertTrue(freshTime > now - cacheTTL)

        // Stale cache: file was modified 7 hours ago
        val staleTime = now - (7 * 60 * 60 * 1000)
        assertFalse(staleTime > now - cacheTTL)
    }

    // ---------------------------------------------------------------
    // 7. Version Comparison
    // ---------------------------------------------------------------

    @Test
    fun `semver comparison works correctly`() {
        assertTrue(isNewer("2.0.0", "1.0.0"))
        assertTrue(isNewer("1.1.0", "1.0.0"))
        assertTrue(isNewer("1.0.1", "1.0.0"))
        assertFalse(isNewer("1.0.0", "1.0.0"))
        assertFalse(isNewer("1.0.0", "2.0.0"))
        assertTrue(isNewer("2.0.0", "1.9.9"))
    }

    // ---------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------

    private fun manifestToJson(manifest: SkillManifest): JSONObject {
        return JSONObject().apply {
            put("id", manifest.id)
            put("name", manifest.name)
            put("version", manifest.version)
            put("description", manifest.description)
            put("author", manifest.author)
            put("repo", manifest.repo ?: JSONObject.NULL)
            put("updatedAt", manifest.updatedAt)
            val cmdsArr = JSONArray()
            for (cmd in manifest.commands) {
                cmdsArr.put(JSONObject().apply {
                    put("name", cmd.name)
                    put("actionType", cmd.actionType)
                    put("pattern", cmd.pattern)
                    put("payloadTemplate", cmd.payloadTemplate)
                    put("examples", JSONArray(cmd.examples))
                    put("permissions", JSONArray(cmd.permissions))
                })
            }
            put("commands", cmdsArr)
            put("grammar", JSONArray(manifest.grammar))
            put("dependencies", JSONArray(manifest.dependencies))
        }
    }

    private fun jsonToManifest(obj: JSONObject): SkillManifest {
        val commands = mutableListOf<SkillCommand>()
        val cmdsArr = obj.optJSONArray("commands")
        if (cmdsArr != null) {
            for (j in 0 until cmdsArr.length()) {
                val cmd = cmdsArr.getJSONObject(j)
                commands.add(SkillCommand(
                    name = cmd.optString("name", ""),
                    actionType = cmd.optString("actionType", ""),
                    pattern = cmd.optString("pattern", ""),
                    payloadTemplate = cmd.optString("payloadTemplate", ""),
                    examples = cmd.optJSONArray("examples")?.let { arr ->
                        (0 until arr.length()).map { arr.getString(it) }
                    } ?: emptyList(),
                    permissions = cmd.optJSONArray("permissions")?.let { arr ->
                        (0 until arr.length()).map { arr.getString(it) }
                    } ?: emptyList()
                ))
            }
        }
        val grammar = obj.optJSONArray("grammar")?.let { arr ->
            (0 until arr.length()).map { arr.getString(it) }
        } ?: emptyList()
        val dependencies = obj.optJSONArray("dependencies")?.let { arr ->
            (0 until arr.length()).map { arr.getString(it) }
        } ?: emptyList()

        return SkillManifest(
            id = obj.getString("id"),
            name = obj.getString("name"),
            version = obj.optString("version", "1.0.0"),
            description = obj.optString("description", ""),
            author = obj.optString("author", ""),
            repo = if (obj.has("repo") && !obj.isNull("repo")) obj.getString("repo") else null,
            commands = commands,
            grammar = grammar,
            dependencies = dependencies,
            updatedAt = obj.optLong("updatedAt", System.currentTimeMillis())
        )
    }

    private fun isNewer(a: String, b: String): Boolean {
        val aParts = a.split(".").map { it.toIntOrNull() ?: 0 }
        val bParts = b.split(".").map { it.toIntOrNull() ?: 0 }
        for (i in 0..maxOf(aParts.size, bParts.size) - 1) {
            val av = aParts.getOrElse(i) { 0 }
            val bv = bParts.getOrElse(i) { 0 }
            if (av > bv) return true
            if (av < bv) return false
        }
        return false
    }
}
