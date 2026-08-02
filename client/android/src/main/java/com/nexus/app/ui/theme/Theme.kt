package com.nexus.app.ui.theme

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable

private val NexusColorScheme = darkColorScheme(
    primary = NexusPrimary,
    onPrimary = NexusOnPrimary,
    primaryContainer = NexusPrimaryContainer,
    secondary = NexusSecondary,
    secondaryContainer = NexusSecondaryContainer,
    background = NexusBackground,
    surface = NexusSurface,
    surfaceVariant = NexusSurfaceVariant,
    error = NexusError,
    errorContainer = NexusErrorContainer,
    onError = NexusOnError,
    onErrorContainer = NexusOnErrorContainer,
    onBackground = NexusOnSurface,
    onSurface = NexusOnSurface,
    onSurfaceVariant = NexusOnSurfaceVariant
)

@Composable
fun NexusTheme(
    content: @Composable () -> Unit
) {
    val colorScheme = NexusColorScheme

    MaterialTheme(
        colorScheme = colorScheme,
        typography = NexusTypography,
        content = content
    )
}
