package com.nexus.app.service

import android.content.pm.ServiceInfo
import android.os.Build
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
class ForegroundServiceTypeResolverTest {

    @Test
    @Config(sdk = [Build.VERSION_CODES.UPSIDE_DOWN_CAKE])
    fun `android 14 with both permissions returns connectedDevice and microphone`() {
        val result = ForegroundServiceTypeResolver.resolve(
            Build.VERSION_CODES.UPSIDE_DOWN_CAKE,
            hasBluetooth = true,
            hasRecordAudio = true
        )
        assertEquals(
            ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE,
            result
        )
    }

    @Test
    @Config(sdk = [Build.VERSION_CODES.UPSIDE_DOWN_CAKE])
    fun `android 14 with only bluetooth returns connectedDevice`() {
        val result = ForegroundServiceTypeResolver.resolve(
            Build.VERSION_CODES.UPSIDE_DOWN_CAKE,
            hasBluetooth = true,
            hasRecordAudio = false
        )
        assertEquals(ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE, result)
    }

    @Test
    @Config(sdk = [Build.VERSION_CODES.UPSIDE_DOWN_CAKE])
    fun `android 14 with only microphone returns microphone`() {
        val result = ForegroundServiceTypeResolver.resolve(
            Build.VERSION_CODES.UPSIDE_DOWN_CAKE,
            hasBluetooth = false,
            hasRecordAudio = true
        )
        assertEquals(ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE, result)
    }

    @Test
    @Config(sdk = [Build.VERSION_CODES.UPSIDE_DOWN_CAKE])
    fun `android 14 with no permissions returns dataSync`() {
        val result = ForegroundServiceTypeResolver.resolve(
            Build.VERSION_CODES.UPSIDE_DOWN_CAKE,
            hasBluetooth = false,
            hasRecordAudio = false
        )
        assertEquals(ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC, result)
    }

    @Test
    @Config(sdk = [Build.VERSION_CODES.R])
    fun `android 11 with bluetooth returns connectedDevice`() {
        val result = ForegroundServiceTypeResolver.resolve(
            Build.VERSION_CODES.R,
            hasBluetooth = true,
            hasRecordAudio = true
        )
        assertEquals(ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE, result)
    }

    @Test
    @Config(sdk = [Build.VERSION_CODES.S])
    fun `android 12 with bluetooth returns connectedDevice`() {
        val result = ForegroundServiceTypeResolver.resolve(
            Build.VERSION_CODES.S,
            hasBluetooth = true,
            hasRecordAudio = true
        )
        assertEquals(ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE, result)
    }

    @Test
    @Config(sdk = [Build.VERSION_CODES.S])
    fun `android 12 without bluetooth returns 0`() {
        val result = ForegroundServiceTypeResolver.resolve(
            Build.VERSION_CODES.S,
            hasBluetooth = false,
            hasRecordAudio = true
        )
        assertEquals(0, result)
    }

    @Test
    @Config(sdk = [Build.VERSION_CODES.P])
    fun `android 9 returns 0`() {
        val result = ForegroundServiceTypeResolver.resolve(
            Build.VERSION_CODES.P,
            hasBluetooth = true,
            hasRecordAudio = true
        )
        assertEquals(0, result)
    }
}
