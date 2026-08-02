package com.nexus.app.service

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
class PermissionCheckerTest {

    @Test
    @Config(sdk = [Build.VERSION_CODES.S])
    fun `android 12 returns true when any bluetooth permission is granted`() {
        val granted = mapOf(Manifest.permission.BLUETOOTH_CONNECT to PackageManager.PERMISSION_GRANTED)
        assertTrue(PermissionChecker.hasBluetoothPermission(Build.VERSION_CODES.S) { granted[it] ?: PackageManager.PERMISSION_DENIED })
    }

    @Test
    @Config(sdk = [Build.VERSION_CODES.S])
    fun `android 12 returns true when only bluetooth scan is granted`() {
        val granted = mapOf(Manifest.permission.BLUETOOTH_SCAN to PackageManager.PERMISSION_GRANTED)
        assertTrue(PermissionChecker.hasBluetoothPermission(Build.VERSION_CODES.S) { granted[it] ?: PackageManager.PERMISSION_DENIED })
    }

    @Test
    @Config(sdk = [Build.VERSION_CODES.S])
    fun `android 12 returns false when no bluetooth permission is granted`() {
        val denied = emptyMap<String, Int>()
        assertFalse(PermissionChecker.hasBluetoothPermission(Build.VERSION_CODES.S) { denied[it] ?: PackageManager.PERMISSION_DENIED })
    }

    @Test
    @Config(sdk = [Build.VERSION_CODES.R])
    fun `android 11 checks legacy bluetooth permission`() {
        val granted = mapOf(Manifest.permission.BLUETOOTH to PackageManager.PERMISSION_GRANTED)
        assertTrue(PermissionChecker.hasBluetoothPermission(Build.VERSION_CODES.R) { granted[it] ?: PackageManager.PERMISSION_DENIED })
    }

    @Test
    @Config(sdk = [Build.VERSION_CODES.R])
    fun `android 11 returns false when legacy bluetooth is denied`() {
        val denied = emptyMap<String, Int>()
        assertFalse(PermissionChecker.hasBluetoothPermission(Build.VERSION_CODES.R) { denied[it] ?: PackageManager.PERMISSION_DENIED })
    }

    @Test
    fun `record audio returns true when granted`() {
        val granted = mapOf(Manifest.permission.RECORD_AUDIO to PackageManager.PERMISSION_GRANTED)
        assertTrue(PermissionChecker.hasRecordAudioPermission { granted[it] ?: PackageManager.PERMISSION_DENIED })
    }

    @Test
    fun `record audio returns false when denied`() {
        val denied = emptyMap<String, Int>()
        assertFalse(PermissionChecker.hasRecordAudioPermission { denied[it] ?: PackageManager.PERMISSION_DENIED })
    }
}
