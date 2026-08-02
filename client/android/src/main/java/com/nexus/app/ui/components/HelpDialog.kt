package com.nexus.app.ui.components

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

/**
 * A scrollable, categorized list of example commands the user can say or type.
 */
@Composable
fun HelpDialog(onDismiss: () -> Unit) {
    val categories = listOf(
        "System" to listOf(
            "Turn on Wi-Fi",
            "Turn off Bluetooth",
            "Set brightness to 50%",
            "Set volume to 30%",
            "Turn on Do Not Disturb",
            "Turn on flashlight"
        ),
        "Media" to listOf(
            "Play chill tunes",
            "Play jazz on Spotify",
            "Next track",
            "Pause music",
            "What's playing?"
        ),
        "Productivity" to listOf(
            "Set a timer for 5 minutes",
            "Set an alarm for 7 am",
            "Take a note that milk expires today",
            "Add eggs to my shopping list",
            "Remind me to call mom at 5 pm",
            "My schedule today"
        ),
        "Navigation & Info" to listOf(
            "What's the weather?",
            "What time is it?",
            "Navigate to home",
            "What's my battery?",
            "Tell me a joke"
        ),
        "Apps & Web" to listOf(
            "Open YouTube",
            "Go to github.com",
            "Search for nearest pizza",
            "Open camera",
            "Take a selfie"
        ),
        "Mesh & Rules" to listOf(
            "Start mesh",
            "Relay lights on",
            "Add a custom rule in settings"
        )
    )

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("What can I say?") },
        text = {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .verticalScroll(rememberScrollState())
            ) {
                Text(
                    text = "Try saying or typing any of these. Nexus learns the phrases you use most.",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
                Spacer(modifier = Modifier.height(16.dp))
                categories.forEach { (title, commands) ->
                    Text(
                        text = title,
                        style = MaterialTheme.typography.titleSmall,
                        color = MaterialTheme.colorScheme.primary
                    )
                    Spacer(modifier = Modifier.height(4.dp))
                    commands.forEach { command ->
                        Text(
                            text = "• $command",
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurface,
                            modifier = Modifier.padding(vertical = 2.dp)
                        )
                    }
                    Spacer(modifier = Modifier.height(12.dp))
                }
            }
        },
        confirmButton = {
            TextButton(onClick = onDismiss) {
                Text("Got it")
            }
        }
    )
}
