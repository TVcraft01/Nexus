package com.nexus.app.skill

import android.content.Context
import android.util.Log
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.net.URL

/**
 * Downloads skill packages from GitHub repos and caches them locally.
 * Each skill is a JSON file hosted in a GitHub release or raw file.
 *
 * The registry repo format:
 * - index.json: list of available skills with their manifest URLs
 * - Each skill is a separate .json file with the SkillManifest format
 */
class SkillDownloader(private val context: Context) {

    companion object {
        private const val TAG = "SkillDownloader"
        /** GitHub repo that hosts the official skill registry */
        const val SKILL_REGISTRY_REPO = "TVcraft01/nexus-skills"
        const val SKILL_REGISTRY_URL = "https://raw.githubusercontent.com/$SKILL_REGISTRY_REPO/main/index.json"
        private const val CACHE_DIR = "skills"
        private const val CACHE_TTL_MS = 6 * 60 * 60 * 1000L // 6 hours
    }

    private val cacheDir: File by lazy {
        File(context.filesDir, CACHE_DIR).also { it.mkdirs() }
    }

    /**
     * Fetch the list of available skills from the registry.
     */
    suspend fun fetchAvailableSkills(): List<SkillManifest> = withContext(Dispatchers.IO) {
        try {
            val url = URL(SKILL_REGISTRY_URL)
            val json = url.readText()
            val arr = JSONArray(json)
            val skills = mutableListOf<SkillManifest>()
            for (i in 0 until arr.length()) {
                val obj = arr.getJSONObject(i)
                skills.add(parseManifest(obj))
            }
            Log.i(TAG, "Fetched ${skills.size} available skills from registry")
            skills
        } catch (e: Exception) {
            Log.w(TAG, "Failed to fetch skill registry: ${e.message}")
            // Return built-in starter skills if registry is unavailable
            getStarterSkills()
        }
    }

    /**
     * Save a skill manifest locally (from the registry index).
     * The index.json already contains commands/grammar inline,
     * so we serialize the manifest to disk for offline access.
     */
    suspend fun downloadSkill(skill: SkillManifest): File? = withContext(Dispatchers.IO) {
        try {
            val skillFile = File(cacheDir, "${skill.id}.json")
            // Check cache freshness
            if (skillFile.exists() && skillFile.lastModified() > System.currentTimeMillis() - CACHE_TTL_MS) {
                Log.d(TAG, "Using cached skill: ${skill.id}")
                return@withContext skillFile
            }
            // Save the manifest locally — index.json already has all the data
            val json = skillToJson(skill)
            skillFile.writeText(json)
            Log.i(TAG, "Saved skill: ${skill.id} v${skill.version}")
            skillFile
        } catch (e: Exception) {
            Log.w(TAG, "Failed to save skill ${skill.id}: ${e.message}")
            null
        }
    }

    /**
     * Serialize a SkillManifest to JSON for local caching.
     */
    private fun skillToJson(skill: SkillManifest): String {
        val obj = JSONObject().apply {
            put("id", skill.id)
            put("name", skill.name)
            put("version", skill.version)
            put("description", skill.description)
            put("author", skill.author)
            put("repo", skill.repo ?: JSONObject.NULL)
            put("updatedAt", skill.updatedAt)
            val cmdsArr = JSONArray()
            for (cmd in skill.commands) {
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
            put("grammar", JSONArray(skill.grammar))
            put("dependencies", JSONArray(skill.dependencies))
        }
        return obj.toString(2)
    }

    /**
     * Load a skill from a local file.
     */
    fun loadFromDisk(skillId: String): SkillManifest? {
        val file = File(cacheDir, "$skillId.json")
        return if (file.exists()) {
            try {
                parseManifest(JSONObject(file.readText()))
            } catch (e: Exception) {
                Log.w(TAG, "Failed to load skill from disk: $skillId", e)
                null
            }
        } else null
    }

    /**
     * List all skills cached on disk.
     */
    fun listCachedSkills(): List<SkillManifest> {
        return cacheDir.listFiles()
            ?.filter { it.extension == "json" && it.name != "index.json" }
            ?.mapNotNull { file ->
                try { parseManifest(JSONObject(file.readText())) } catch (_: Exception) { null }
            }
            ?: emptyList()
    }

    /** Clear the skill cache */
    fun clearCache() {
        cacheDir.deleteRecursively()
        cacheDir.mkdirs()
    }

    private fun parseManifest(obj: JSONObject): SkillManifest {
        val commands = mutableListOf<SkillCommand>()
        val commandsArr = obj.optJSONArray("commands")
        if (commandsArr != null) {
            for (i in 0 until commandsArr.length()) {
                val cmd = commandsArr.getJSONObject(i)
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

    /**
     * Starter skills shipped with the app — a minimal base that the system
     * can use before any skills are downloaded. These are intentionally
     * minimal; the real knowledge comes from downloaded skills.
     */
    /**
     * Empty starter skill — the app ships with zero commands.
     * Everything is learned from the user or downloaded from the skill repo.
     */
    fun getStarterSkills(): List<SkillManifest> = listOf(
        SkillManifest(
            id = "com.nexus.starter",
            name = "Starter",
            version = "0.1.0",
            description = "Empty base — all knowledge is learned or downloaded",
            author = "Nexus",
            commands = emptyList(),
            grammar = emptyList()
        )
    )
}
