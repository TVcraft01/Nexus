package com.nexus.app.ui.components

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.unit.dp

/**
 * A Nothing/Apple inspired dot-grid sound wave visualizer.
 *
 * Renders a grid of circular dots. When [active] is true, the dots react with
 * a pulsing wave pattern. The intensity is driven by [amplitude] (0..1).
 */
@Composable
fun DotGridVisualizer(
    modifier: Modifier = Modifier,
    active: Boolean = true,
    amplitude: Float = 0.5f,
    dotColor: Color = MaterialTheme.colorScheme.onSurface,
    gridColumns: Int = 9,
    gridRows: Int = 9
) {
    val animatedAmplitude by animateFloatAsState(
        targetValue = if (active) amplitude.coerceIn(0f, 1f) else 0.05f,
        label = "VisualizerAmplitude"
    )

    Canvas(modifier = modifier.size(160.dp)) {
        val canvasWidth = size.width
        val canvasHeight = size.height
        val padding = 8.dp.toPx()
        val availableWidth = canvasWidth - padding * 2
        val availableHeight = canvasHeight - padding * 2
        val dotRadius = (availableWidth / gridColumns).coerceAtMost(availableHeight / gridRows) * 0.18f
        val spacingX = availableWidth / gridColumns
        val spacingY = availableHeight / gridRows

        val centerX = gridColumns / 2f
        val centerY = gridRows / 2f

        for (row in 0 until gridRows) {
            for (col in 0 until gridColumns) {
                val dx = col - centerX
                val dy = row - centerY
                val distance = kotlin.math.hypot(dx.toDouble(), dy.toDouble()).toFloat()
                val maxDistance = kotlin.math.hypot(centerX.toDouble(), centerY.toDouble()).toFloat()
                val normalizedDistance = distance / maxDistance

                // Create a wave effect radiating from the center.
                val wave = (1f - normalizedDistance) * animatedAmplitude
                val alpha = 0.2f + wave * 0.8f
                val radius = dotRadius * (0.5f + wave)

                val x = padding + spacingX * (col + 0.5f)
                val y = padding + spacingY * (row + 0.5f)

                drawCircle(
                    color = dotColor.copy(alpha = alpha.coerceIn(0.05f, 1f)),
                    radius = radius.coerceAtLeast(1.5f),
                    center = Offset(x, y)
                )
            }
        }
    }
}

/**
 * A small variant used in inline UI chips and buttons.
 */
@Composable
fun MiniDotGridVisualizer(
    modifier: Modifier = Modifier,
    active: Boolean = true
) {
    DotGridVisualizer(
        modifier = modifier,
        active = active,
        amplitude = if (active) 0.8f else 0.2f,
        gridColumns = 5,
        gridRows = 5
    )
}
