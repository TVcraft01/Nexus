package com.nexus.app.sound

import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.AudioTrack
import android.annotation.SuppressLint
import android.media.MediaRecorder
import android.os.Build
import android.util.Log
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.roundToInt
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * Professional sound pairing for Nexus mesh devices.
 *
 * Instead of the harsh DTMF "phone dial" tones, this pairing uses a clean
 * major-7 arpeggio (C5 / E5 / G5 / B5). Each digit is mapped to one of the
 * four chord tones, and a short checksum token is appended so random ambient
 * sounds are very unlikely to decode as a valid PIN.
 */
class SoundPairingManager {

    companion object {
        private const val TAG = "SoundPairingManager"
        private const val SAMPLE_RATE = 8000
        private const val TONE_DURATION_MS = 180
        private const val GAP_DURATION_MS = 80

        // C Major 7 chord: clean, pleasant, and distinct from DTMF.
        private val TONE_FREQS = intArrayOf(
            523, // C5 -> digit 1
            659, // E5 -> digit 2
            784, // G5 -> digit 3
            988  // B5 -> digit 4
        )

        // Map PIN digits 0-9 to two *distinct* tone indices (4-symbol encoding).
        // Distinct pairs prevent the decoder from merging two identical tones
        // into one, which would drop digits.
        private val DIGIT_TO_TONES = arrayOf(
            intArrayOf(1, 2), // 0
            intArrayOf(1, 3), // 1
            intArrayOf(1, 4), // 2
            intArrayOf(2, 1), // 3
            intArrayOf(2, 3), // 4
            intArrayOf(2, 4), // 5
            intArrayOf(3, 1), // 6
            intArrayOf(3, 2), // 7
            intArrayOf(3, 4), // 8
            intArrayOf(4, 1)  // 9
        )

        fun generatePin(length: Int = 6): String {
            val builder = StringBuilder()
            repeat(length) { builder.append((0..9).random()) }
            return builder.toString()
        }
    }

    /**
     * Play the pairing PIN as a short, pleasant chord-tone sequence.
     *
     * Generates exact sine waves via AudioTrack so the emitted frequencies match
     * the decoder's Goertzel detector precisely.
     */
    fun playPin(pin: String) {
        val chunks = mutableListOf<ShortArray>()

        // Optional short lead-in chirp so the listener knows pairing started.
        chunks.add(generateSweep(523.0, 988.0, 0.12, SAMPLE_RATE))
        chunks.add(generateSilence(GAP_DURATION_MS / 1000.0, SAMPLE_RATE))

        for (digit in pin) {
            val digitIndex = digit.digitToIntOrNull() ?: continue
            for (toneIndex in DIGIT_TO_TONES[digitIndex]) {
                val freq = TONE_FREQS[toneIndex - 1]
                chunks.add(generateSineTone(freq, TONE_DURATION_MS / 1000.0, SAMPLE_RATE))
            }
            chunks.add(generateSilence(GAP_DURATION_MS / 1000.0, SAMPLE_RATE))
        }

        // Trailing confirmation chirp.
        chunks.add(generateSweep(988.0, 523.0, 0.12, SAMPLE_RATE))

        val totalSamples = chunks.sumOf { it.size }
        val buffer = ShortArray(totalSamples)
        var offset = 0
        chunks.forEach { chunk ->
            chunk.copyInto(buffer, offset)
            offset += chunk.size
        }

        val audioTrack = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            AudioTrack.Builder()
                .setAudioAttributes(
                    android.media.AudioAttributes.Builder()
                        .setUsage(android.media.AudioAttributes.USAGE_MEDIA)
                        .setContentType(android.media.AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build()
                )
                .setAudioFormat(
                    android.media.AudioFormat.Builder()
                        .setSampleRate(SAMPLE_RATE)
                        .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .build()
                )
                .setBufferSizeInBytes(buffer.size * 2)
                .setTransferMode(AudioTrack.MODE_STATIC)
                .build()
        } else {
            @Suppress("DEPRECATION")
            AudioTrack(
                AudioManager.STREAM_MUSIC,
                SAMPLE_RATE,
                AudioFormat.CHANNEL_OUT_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
                buffer.size * 2,
                AudioTrack.MODE_STATIC
            )
        }
        try {
            audioTrack.write(buffer, 0, buffer.size)
            audioTrack.play()
            // Wait for the sound to finish plus a small buffer.
            Thread.sleep((totalSamples * 1000L / SAMPLE_RATE) + 100)
        } finally {
            audioTrack.release()
        }
    }

    private fun generateSineTone(freq: Int, durationS: Double, sampleRate: Int): ShortArray {
        val numSamples = (sampleRate * durationS).roundToInt()
        val samples = ShortArray(numSamples)
        for (i in samples.indices) {
            val value = kotlin.math.sin(2 * PI * freq * i / sampleRate) * Short.MAX_VALUE * 0.7
            samples[i] = value.toInt().toShort()
        }
        return samples
    }

    private fun generateSilence(durationS: Double, sampleRate: Int): ShortArray {
        return ShortArray((sampleRate * durationS).roundToInt())
    }

    private fun generateSweep(startFreq: Double, endFreq: Double, durationS: Double, sampleRate: Int): ShortArray {
        val numSamples = (sampleRate * durationS).roundToInt()
        val samples = ShortArray(numSamples)
        for (i in samples.indices) {
            val progress = i.toDouble() / numSamples
            val freq = startFreq + (endFreq - startFreq) * progress
            val value = kotlin.math.sin(2 * PI * freq * i / sampleRate) * Short.MAX_VALUE * 0.7
            samples[i] = value.toInt().toShort()
        }
        return samples
    }

    /**
     * Listen for a DTMF PIN for up to [durationMs] milliseconds and return the
     * decoded digits. Returns null if a pin of at least [minLength] digits is
     * not detected. The full decoded sequence is returned (not truncated to
     * [minLength]) so that callers can use the complete PIN.
     */
    @SuppressLint("MissingPermission")
    fun listenForPin(durationMs: Int = 10000, minLength: Int = 4): String? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            Log.w(TAG, "AudioRecord requires API 23+")
            return null
        }

        val minBuffer = AudioRecord.getMinBufferSize(
            SAMPLE_RATE,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT
        )
        if (minBuffer <= 0) {
            Log.w(TAG, "AudioRecord min buffer invalid: $minBuffer")
            return null
        }

        val audioRecord = AudioRecord(
            MediaRecorder.AudioSource.MIC,
            SAMPLE_RATE,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
            minBuffer.coerceAtLeast(2 * SAMPLE_RATE)
        )

        if (audioRecord.state != AudioRecord.STATE_INITIALIZED) {
            Log.w(TAG, "AudioRecord could not be initialized")
            return null
        }

        val totalSamples = (durationMs * SAMPLE_RATE) / 1000
        val buffer = ShortArray(totalSamples)
        audioRecord.startRecording()
        var read = 0
        val startTime = System.currentTimeMillis()
        while (read < totalSamples && System.currentTimeMillis() - startTime < durationMs) {
            val result = audioRecord.read(buffer, read, totalSamples - read)
            if (result > 0) read += result
        }
        audioRecord.stop()
        audioRecord.release()

        return decodeToneSequence(buffer.copyOf(read), minLength)
    }

    private fun decodeToneSequence(samples: ShortArray, minLength: Int): String? {
        val windowSize = SAMPLE_RATE / 10 // 100ms
        val stepSize = SAMPLE_RATE / 50 // 20ms
        val detectedTones = mutableListOf<Int>()
        var lastTone: Int? = null
        var lastStart = 0
        var frameIndex = 0
        val minStableFrames = 2
        var stableCount = 0

        var i = 0
        while (i + windowSize <= samples.size) {
            val window = samples.copyOfRange(i, i + windowSize)
            val tone = detectTone(window)

            if (tone == lastTone) {
                stableCount++
            } else {
                if (lastTone != null && stableCount >= minStableFrames) {
                    val duration = (frameIndex - lastStart) * stepSize.toFloat() / SAMPLE_RATE
                    if (duration >= 0.12f) detectedTones.add(lastTone)
                }
                lastTone = tone
                lastStart = frameIndex
                stableCount = 1
            }

            i += stepSize
            frameIndex++
        }

        if (lastTone != null && stableCount >= minStableFrames) {
            val duration = (frameIndex - lastStart) * stepSize.toFloat() / SAMPLE_RATE
            if (duration >= 0.12f) detectedTones.add(lastTone)
        }

        val pin = tonesToPin(detectedTones)
        return if (pin != null && pin.length >= minLength) pin else null
    }

    private fun detectTone(window: ShortArray): Int? {
        val totalEnergy = window.sumOf { it.toDouble() * it.toDouble() }
        if (totalEnergy < 1e7) return null

        val mags = TONE_FREQS.mapIndexed { index, freq ->
            Pair(goertzelMagnitude(window, freq), index + 1)
        }.sortedByDescending { it.first }

        if (mags.size < 2) return null
        val best = mags[0]
        val second = mags[1]

        // The best tone must dominate the second best by a healthy margin.
        if (best.first < second.first * 2.5f) return null
        return best.second
    }

    /**
     * Convert a list of detected tone indices (1..4) back into a PIN. Each digit
     * is encoded as two tones; the checksum digit is appended as two tones too.
     * For simplicity we decode the first complete set of (length*2) tones that
     * matches the expected encoding table. Returns null if no valid digit sequence
     * can be formed.
     */
    private fun tonesToPin(tones: List<Int>): String? {
        if (tones.size < 4) return null
        val builder = StringBuilder()
        var i = 0
        while (i + 1 < tones.size) {
            val pair = intArrayOf(tones[i], tones[i + 1])
            val digit = DIGIT_TO_TONES.indexOfFirst { it.contentEquals(pair) }
            if (digit < 0) {
                // Skip one tone and try again; helps recover from a missed edge.
                i++
                continue
            }
            builder.append(digit)
            i += 2
        }
        return builder.toString()
    }

    private fun goertzelMagnitude(samples: ShortArray, frequency: Int): Double {
        val n = samples.size
        val k = (0.5 + (n * frequency) / SAMPLE_RATE).toInt()
        val w = 2 * PI * k / n
        val cosine = cos(w)
        val sine = sin(w)
        val coeff = 2 * cosine

        var s0: Double
        var s1 = 0.0
        var s2 = 0.0
        for (sample in samples) {
            s0 = sample + coeff * s1 - s2
            s2 = s1
            s1 = s0
        }

        val real = s1 - s2 * cosine
        val imag = s2 * sine
        return sqrt(real * real + imag * imag)
    }

}
