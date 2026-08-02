package com.nexus.app

import android.app.Application
import android.content.Intent
import android.os.Build
import android.util.Log
import com.nexus.app.brain.AdaptiveEngine
import com.nexus.app.command.LearningRepository
import com.nexus.app.command.RoutineRepository
import com.nexus.app.skill.SkillRegistry
import com.nexus.app.data.local.NexusDatabase
import com.nexus.app.data.security.VaultKeyManager
import com.nexus.app.discovery.AppCapabilityAnalyzer
import com.nexus.app.discovery.AppCapabilityIndex
import com.nexus.app.discovery.AppScanner
import com.nexus.app.discovery.CapabilityRouter
import com.nexus.app.hardware.ExecutionMode
import com.nexus.app.hardware.HardwareManager
import com.nexus.app.service.NexusMeshService
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

class NexusApplication : Application() {

    private val applicationScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    lateinit var hardwareManager: HardwareManager
        private set

    val learningRepository: LearningRepository by lazy { LearningRepository(this) }

    // Shared routine repository: detected recurring SET_ALARM handoffs, synced
    // across the mesh (ROUTINE_SYNC) alongside learned commands. A single shared
    // instance so both the ViewModel (recording handoffs) and the mesh service
    // (broadcasting on change) observe the same store.
    val routineRepository: RoutineRepository by lazy { RoutineRepository(database) }

    // --- Skill System ---
    // Commands, patterns, and grammar are downloaded as skills from a GitHub repo.
    // The app ships with a minimal starter skill; the real knowledge grows as
    // the user installs community skills and the adaptive engine learns.
    val skillRegistry: SkillRegistry by lazy { SkillRegistry(this) }

    val database: NexusDatabase by lazy {
        NexusDatabase.getInstance(
            context = this,
            passphraseProvider = { VaultKeyManager.getOrCreatePassphrase(this) }
        )
    }

    // --- Adaptive Learning Engine ---
    // The brain's learning layer: passively records every command with context,
    // discovers patterns over time, and resolves ambiguous commands using
    // learned habits + time/recent actions. Grows smarter with every use.
    val adaptiveEngine: AdaptiveEngine by lazy { AdaptiveEngine(database) }

    // --- App Capability Discovery & Tagging ---
    // Universally discovers installed apps, tags them by capability, and
    // routes commands to the best app. No hardcoded app names.
    private val _capabilityIndex by lazy { AppCapabilityIndex(this) }
    val capabilityIndex: AppCapabilityIndex get() = _capabilityIndex
    val capabilityRouter: CapabilityRouter by lazy { CapabilityRouter(this, capabilityIndex) }

    override fun onCreate() {
        super.onCreate()

        hardwareManager = HardwareManager(this)
        val mode = hardwareManager.determineExecutionMode()

        // Ensure the first (expensive) database open happens off the main thread.
        applicationScope.launch(Dispatchers.IO) {
            database.memoryLogDao().insert(
                message = "Nexus booted in ${mode.displayName}. Available RAM: ${hardwareManager.availableRamMb} MB",
                level = "INFO"
            )
        }

        // Background: scan installed apps and tag them by capability.
        // This feeds the CapabilityRouter so "open X", "navigate to Y",
        // "play Z" all adapt to whatever apps the user has installed.
        applicationScope.launch(Dispatchers.IO) {
            try {
                val scanner = AppScanner(this@NexusApplication)
                val analyzer = AppCapabilityAnalyzer(this@NexusApplication)
                capabilityRouter.scanAndIndexAllApps(scanner, analyzer)
                Log.i(
                    "NexusApplication",
                    "App capability index refreshed: ${capabilityIndex.size()} apps tagged"
                )
            } catch (e: Exception) {
                Log.w("NexusApplication", "App capability scan failed", e)
            }
        }
    }
}
