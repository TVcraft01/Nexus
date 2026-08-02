package com.nexus.app.ui

import android.graphics.Bitmap
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

@RunWith(RobolectricTestRunner::class)
class QrCodeGeneratorTest {

    @Test
    fun `generate returns square bitmap with requested size`() {
        val bitmap = QrCodeGenerator.generate("test", 256)
        assertNotNull(bitmap)
        assertEquals(256, bitmap.width)
        assertEquals(256, bitmap.height)
    }

    @Test
    fun `generate returns distinct bitmaps for different contents`() {
        val a = QrCodeGenerator.generate("content-a", 128)
        val b = QrCodeGenerator.generate("content-b", 128)

        var differentPixels = 0
        for (x in 0 until a.width step 4) {
            for (y in 0 until a.height step 4) {
                if (a.getPixel(x, y) != b.getPixel(x, y)) {
                    differentPixels++
                }
            }
        }
        assertTrue("Bitmaps for different payloads should differ", differentPixels > 0)
    }

    @Test
    fun `generate returns same bitmap for same contents and size`() {
        val a = QrCodeGenerator.generate("same-content", 128)
        val b = QrCodeGenerator.generate("same-content", 128)

        var matchingPixels = 0
        for (x in 0 until a.width) {
            for (y in 0 until a.height) {
                if (a.getPixel(x, y) == b.getPixel(x, y)) {
                    matchingPixels++
                }
            }
        }
        assertEquals(a.width * a.height, matchingPixels)
    }

    private fun assertTrue(message: String, condition: Boolean) {
        if (!condition) throw AssertionError(message)
    }
}
