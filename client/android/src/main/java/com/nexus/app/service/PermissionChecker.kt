package com.nexus.app.service

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build

/**
 * Pure helpers for deciding whether the app has been granted the runtime
 * permissions used by [NexusMeshService].
 *
 * The functions accept a lambda instead of a [android.content.Context] so they
 * can be unit-tested without Android framework dependencies.
 */
object PermissionChecker {

    /**
     * Returns true if the app has a Bluetooth permission appropriate for the
     * current Android version.
     *
     * On Android 12+ (API 31+) one of BLUETOOTH_CONNECT, BLUETOOTH_SCAN or
     * BLUETOOTH_ADVERTISE is required. On earlier versions the legacy
     * BLUETOOTH permission is checked.
     *
     * @param sdkVersion current value of [Build.VERSION.SDK_INT]
     * @param checkPermission lambda that returns [PackageManager.PERMISSION_GRANTED]
     *                        or another value for the supplied permission name
     */
    fun hasBluetoothPermission(
        sdkVersion: Int,
        checkPermission: (String) -> Int
    ): Boolean {
        return if (sdkVersion >= Build.VERSION_CODES.S) {
            listOf(
                Manifest.permission.BLUETOOTH_CONNECT,
                Manifest.permission.BLUETOOTH_SCAN,
                Manifest.permission.BLUETOOTH_ADVERTISE
            ).any { checkPermission(it) == PackageManager.PERMISSION_GRANTED }
        } else {
            checkPermission(Manifest.permission.BLUETOOTH) == PackageManager.PERMISSION_GRANTED
        }
    }

    /**
     * Returns true if the app has been granted [Manifest.permission.RECORD_AUDIO].
     *
     * @param checkPermission lambda that returns [PackageManager.PERMISSION_GRANTED]
     *                        or another value for [Manifest.permission.RECORD_AUDIO]
     */
    fun hasRecordAudioPermission(checkPermission: (String) -> Int): Boolean {
        return checkPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
    }
}
