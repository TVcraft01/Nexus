package com.nexus.app.ui

import android.graphics.Bitmap
import android.graphics.Color
import com.google.zxing.BarcodeFormat
import com.google.zxing.qrcode.QRCodeWriter

/**
 * Generates QR code bitmaps for Nexus device pairing payloads.
 */
object QrCodeGenerator {

    /**
     * Generates a square monochrome QR code bitmap encoding [contents].
     *
     * @param contents the string to encode
     * @param size the desired width/height in pixels; defaults to 512
     * @return a [Bitmap] containing the generated QR code
     */
    fun generate(contents: String, size: Int = 512): Bitmap {
        val writer = QRCodeWriter()
        val bitMatrix = writer.encode(contents, BarcodeFormat.QR_CODE, size, size)
        val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.RGB_565)
        for (x in 0 until size) {
            for (y in 0 until size) {
                bitmap.setPixel(x, y, if (bitMatrix.get(x, y)) Color.BLACK else Color.WHITE)
            }
        }
        return bitmap
    }
}
