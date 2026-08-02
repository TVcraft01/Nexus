package com.nexus.app.skill

import android.content.Context
import android.util.Log
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * Tracks which skills are installed, enabled, and available for update.
 * Persists the installed skill list to disk so it survives app restarts.
 */
class SkillRegistry(private val context: Context) {

    companion object {
        private const val TAG = "SkillRegistry"
        private const val REGISTRY_FILE = "installed_skills.json"
    }

    private val downloader = SkillDownloader(context)
    private val registryFile = File(context.filesDir, REGISTRY_FILE)

    private val installedSkills = java.util.concurrent.ConcurrentHashMap<String, InstalledSkill>()
    private var loaded = false

    init {
        loadFromDisk()
        // Auto-install starter skill on first boot so the Vosk grammar
        // isn't empty before the user downloads community skills.
        if (installedSkills.isEmpty()) {
            val starter = downloader.getStarterSkills().firstOrNull()
            if (starter != null) {
                installedSkills[starter.id] = InstalledSkill(
                    manifest = starter,
                    enabled = true
                )
                saveToDisk()
            }
        }
    }

    /**
     * Get all installed and enabled skills.
     */
    fun getEnabledSkills(): List<InstalledSkill> {
        return installedSkills.values.filter { it.enabled }
    }

    /**
     * Get all installed skills (enabled + disabled).
     */
    fun getAllSkills(): List<InstalledSkill> {
        return installedSkills.values.toList()
    }

    /**
     * Install a skill from its manifest.
     */
    suspend fun installSkill(manifest: SkillManifest): Boolean = withContext(Dispatchers.IO) {
        try {
            // Download the skill file
            val file = downloader.downloadSkill(manifest) ?: return@withContext false
            installedSkills[manifest.id] = InstalledSkill(
                manifest = manifest,
                enabled = true,
                localPath = file.absolutePath
            )
            saveToDisk()
            Log.i(TAG, "Installed skill: ${manifest.id} v${manifest.version}")
            true
        } catch (e: Exception) {
            Log.w(TAG, "Failed to install skill ${manifest.id}", e)
            false
        }
    }

    /**
     * Enable or disable a skill.
     */
    fun setSkillEnabled(skillId: String, enabled: Boolean) {
        installedSkills[skillId]?.let {
            installedSkills[skillId] = it.copy(enabled = enabled)
            saveToDisk()
        }
    }

    /**
     * Remove a skill.
     */
    fun removeSkill(skillId: String) {
        installedSkills.remove(skillId)
        // Delete cached file
        File(context.filesDir, "skills/$skillId.json").delete()
        saveToDisk()
    }

    /**
     * Check for available updates from the registry.
     */
    suspend fun checkForUpdates(): List<Pair<InstalledSkill, SkillManifest>> = withContext(Dispatchers.IO) {
        val available = downloader.fetchAvailableSkills()
        val updates = mutableListOf<Pair<InstalledSkill, SkillManifest>>()
        for (availableSkill in available) {
            val installed = installedSkills[availableSkill.id]
            if (installed != null && isNewer(availableSkill.version, installed.manifest.version)) {
                updates.add(installed to availableSkill)
            }
        }
        updates
    }

    /**
     * Update a skill to the latest version.
     */
    suspend fun updateSkill(skillId: String): Boolean {
        val available = downloader.fetchAvailableSkills()
        val latest = available.find { it.id == skillId } ?: return false
        return installSkill(latest)
    }

    /**
     * Fetch all commands from enabled skills.
     */
    fun getAllCommands(): List<SkillCommand> {
        return getEnabledSkills().flatMap { it.manifest.commands }
    }

    /**
     * Fetch all grammar entries from enabled skills.
     */
    fun getAllGrammar(): List<String> {
        return getEnabledSkills().flatMap { it.manifest.grammar }.distinct()
    }

    /**
     * Fetch all command patterns from enabled skills (as regex strings).
     */
    fun getAllPatterns(): List<Pair<String, String>> {
        // Returns list of (pattern, actionType) pairs
        return getEnabledSkills().flatMap { skill ->
            skill.manifest.commands.map { it.pattern to it.actionType }
        }
    }

    // --- Persistence ---

    @Synchronized
    private fun saveToDisk() {
        try {
            val arr = JSONArray()
            for (skill in installedSkills.values) {
                val manifestObj = JSONObject().apply {
                    put("id", skill.manifest.id)
                    put("name", skill.manifest.name)
                    put("version", skill.manifest.version)
                    put("description", skill.manifest.description)
                    put("author", skill.manifest.author)
                    put("repo", skill.manifest.repo ?: JSONObject.NULL)
                    put("updatedAt", skill.manifest.updatedAt)
                    // Serialize commands so they survive app restart
                    val cmdsArr = JSONArray()
                    for (cmd in skill.manifest.commands) {
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
                    // Serialize grammar so voice recognition survives restart
                    put("grammar", JSONArray(skill.manifest.grammar))
                    // Serialize dependencies
                    put("dependencies", JSONArray(skill.manifest.dependencies))
                }
                val obj = JSONObject().apply {
                    put("id", skill.manifest.id)
                    put("version", skill.manifest.version)
                    put("enabled", skill.enabled)
                    put("installedAt", skill.installedAt)
                    put("manifest", manifestObj)
                }
                arr.put(obj)
            }
            registryFile.writeText(arr.toString(2))
        } catch (e: Exception) {
            Log.w(TAG, "Failed to save registry", e)
        }
    }

    @Synchronized
    private fun loadFromDisk() {
        if (loaded) return
        loaded = true
        try {
            if (!registryFile.exists()) return
            val arr = JSONArray(registryFile.readText())
            for (i in 0 until arr.length()) {
                val obj = arr.getJSONObject(i)
                val id = obj.getString("id")
                val manifestObj = obj.optJSONObject("manifest")
                val manifest = if (manifestObj != null) {
                    // Parse commands from serialized JSON
                    val commands = mutableListOf<SkillCommand>()
                    val cmdsArr = manifestObj.optJSONArray("commands")
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
                    // Parse grammar from serialized JSON
                    val grammar = manifestObj.optJSONArray("grammar")?.let { arr ->
                        (0 until arr.length()).map { arr.getString(it) }
                    } ?: emptyList()
                    // Parse dependencies
                    val dependencies = manifestObj.optJSONArray("dependencies")?.let { arr ->
                        (0 until arr.length()).map { arr.getString(it) }
                    } ?: emptyList()
                    SkillManifest(
                        id = manifestObj.getString("id"),
                        name = manifestObj.getString("name"),
                        version = manifestObj.getString("version"),
                        description = manifestObj.optString("description", ""),
                        author = manifestObj.optString("author", ""),
                        repo = if (manifestObj.has("repo") && !manifestObj.isNull("repo")) manifestObj.getString("repo") else null,
                        commands = commands,
                        grammar = grammar,
                        dependencies = dependencies,
                        updatedAt = manifestObj.optLong("updatedAt", System.currentTimeMillis())
                    )
                } else {
                    // Try loading from cached skill file
                    downloader.loadFromDisk(id) ?: continue
                }
                installedSkills[id] = InstalledSkill(
                    manifest = manifest,
                    enabled = obj.optBoolean("enabled", true),
                    installedAt = obj.optLong("installedAt", System.currentTimeMillis())
                )
            }
            Log.i(TAG, "Loaded ${installedSkills.size} installed skills")
        } catch (e: Exception) {
            Log.w(TAG, "Failed to load registry", e)
        }
    }

    /** Simple semver comparison: returns true if `a` is newer than `b` */
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
