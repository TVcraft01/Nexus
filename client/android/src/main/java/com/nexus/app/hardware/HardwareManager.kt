package com.nexus.app.hardware

import android.app.ActivityManager
import android.content.Context
import android.os.Build
import android.os.Process
import androidx.core.content.ContextCompat

class HardwareManager(private val context: Context) {

    companion object {
        const val THIN_NODE_RAM_THRESHOLD_MB = 1024L
        const val SLM_MIN_RAM_MB = 2048L
    }

    private val activityManager: ActivityManager? =
        ContextCompat.getSystemService(context, ActivityManager::class.java)

    val availableRamMb: Long
        get() {
            val memoryInfo = ActivityManager.MemoryInfo()
            activityManager?.getMemoryInfo(memoryInfo)
            return memoryInfo.availMem / (1024 * 1024)
        }

    val totalRamMb: Long
        get() {
            val memoryInfo = ActivityManager.MemoryInfo()
            activityManager?.getMemoryInfo(memoryInfo)
            return memoryInfo.totalMem / (1024 * 1024)
        }

    val isLowMemory: Boolean
        get() {
            val memoryInfo = ActivityManager.MemoryInfo()
            activityManager?.getMemoryInfo(memoryInfo)
            return memoryInfo.lowMemory
        }

    fun determineExecutionMode(): ExecutionMode {
        val available = availableRamMb
        return if (available < THIN_NODE_RAM_THRESHOLD_MB) {
            ExecutionMode.THIN_NODE
        } else {
            ExecutionMode.STANDARD_EDGE
        }
    }

    fun canRunLocalSlm(): Boolean {
        return availableRamMb >= SLM_MIN_RAM_MB && !isLowMemory
    }

    fun deviceSummary(): String {
        val builder = StringBuilder()
        builder.append("Device: ").append(Build.MANUFACTURER).append(" ").append(Build.MODEL).append("\n")
        builder.append("Total RAM: ").append(totalRamMb).append(" MB\n")
        builder.append("Available RAM: ").append(availableRamMb).append(" MB\n")
        builder.append("Mode: ").append(determineExecutionMode().displayName).append("\n")
        builder.append("SLM Capable: ").append(canRunLocalSlm())
        return builder.toString()
    }
}
