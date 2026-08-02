package com.nexus.app.service

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * Test-only broadcast receiver that lets adb trigger pairing with a peer node.
 *
 * Usage (from a host connected via adb):
 *   adb shell am broadcast -a com.nexus.app.action.TEST_PAIR \
 *     --es peer_id <desktop_node_id> \
 *     --es pin <six_digit_pin>
 */
class TestPairingReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION_TEST_PAIR) return

        val peerId = intent.getStringExtra(EXTRA_PEER_ID)
        val pin = intent.getStringExtra(EXTRA_PIN)

        if (peerId.isNullOrBlank() || pin.isNullOrBlank()) {
            Log.w(TAG, "Ignoring test pair broadcast: missing peer_id or pin")
            return
        }

        Log.i(TAG, "Received test pair broadcast for peer=$peerId")

        val serviceIntent = Intent(context, NexusMeshService::class.java).apply {
            action = ACTION_SERVICE_PAIR
            putExtra(EXTRA_PEER_ID, peerId)
            putExtra(EXTRA_PIN, pin)
        }
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
            context.startForegroundService(serviceIntent)
        } else {
            @Suppress("DEPRECATION")
            context.startService(serviceIntent)
        }
    }

    companion object {
        const val TAG = "TestPairingReceiver"
        const val ACTION_TEST_PAIR = "com.nexus.app.action.TEST_PAIR"
        const val ACTION_SERVICE_PAIR = "com.nexus.app.action.PAIR_NODE"
        const val EXTRA_PEER_ID = "peer_id"
        const val EXTRA_PIN = "pin"
    }
}
