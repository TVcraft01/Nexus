package com.nexus.app.service

import android.content.pm.ServiceInfo
import android.os.Build

/**
 * Resolves the correct foreground service type flags for [NexusMeshService]
 * based on the current Android SDK version and the runtime permissions that
 * have been granted.
 *
 * Android 14+ forbids a foreground service type of 0 ("none"). The helper
 * therefore falls back to [ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC] when
 * neither Bluetooth nor microphone permissions are available yet.
 */
object ForegroundServiceTypeResolver {

    /**
     * Returns the foreground service type flags to use when starting
     * [NexusMeshService].
     *
     * @param sdkVersion current value of [Build.VERSION.SDK_INT]
     * @param hasBluetooth true if the app has been granted a Bluetooth permission
     * @param hasRecordAudio true if the app has been granted [android.permission.RECORD_AUDIO]
     */
    fun resolve(sdkVersion: Int, hasBluetooth: Boolean, hasRecordAudio: Boolean): Int {
        return when {
            sdkVersion >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE -> resolveUpsideDownCake(hasBluetooth, hasRecordAudio)
            sdkVersion >= Build.VERSION_CODES.R -> {
                if (hasBluetooth) ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE else 0
            }
            else -> 0
        }
    }

    private fun resolveUpsideDownCake(hasBluetooth: Boolean, hasRecordAudio: Boolean): Int {
        return when {
            hasBluetooth && hasRecordAudio -> {
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
            }
            hasBluetooth -> ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
            hasRecordAudio -> ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
            else -> ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
        }
    }
}
