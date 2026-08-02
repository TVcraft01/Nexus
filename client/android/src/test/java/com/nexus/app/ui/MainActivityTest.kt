package com.nexus.app.ui

import android.os.Build
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowToast

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [Build.VERSION_CODES.S])
class MainActivityTest {

    @Test
    fun `handleScannedQr shows toast for invalid QR content`() {
        val activity = Robolectric.buildActivity(MainActivity::class.java).create().get()

        activity.handleScannedQr("not-valid-json")

        assertEquals("Invalid Nexus QR code", ShadowToast.getTextOfLatestToast())
    }

    @Test
    fun `handleScannedQr shows toast for QR with missing fields`() {
        val activity = Robolectric.buildActivity(MainActivity::class.java).create().get()

        activity.handleScannedQr("""{\"nodeId\":\"abc\",\"pin\":\"\"}""")

        assertEquals("Invalid Nexus QR code", ShadowToast.getTextOfLatestToast())
    }
}
