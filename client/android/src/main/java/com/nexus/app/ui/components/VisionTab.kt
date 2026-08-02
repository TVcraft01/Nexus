package com.nexus.app.ui.components

import android.graphics.Bitmap
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Camera
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material.icons.filled.Videocam
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nexus.app.ui.theme.*
import com.nexus.app.ui.viewmodel.NexusUiState

/**
 * Vision tab — mirrors the desktop's Vision tab (🎥).
 *
 * Features:
 * - Camera selector dropdown
 * - Live preview with YOLO detection overlay
 * - FPS slider (1-15)
 * - Snapshot button
 * - Search cameras input
 * - Locate item input
 * - Vision + MQTT status indicators
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun VisionTab(
    state: NexusUiState,
    onCameraSelected: (String) -> Unit,
    onTogglePreview: () -> Unit,
    onFpsChanged: (Int) -> Unit,
    onSnapshot: () -> Unit,
    onSearch: (String) -> Unit,
    onLocate: (String) -> Unit,
    onRefreshStatus: () -> Unit
) {
    var searchQuery by rememberSaveable { mutableStateOf("") }
    var locateItem by rememberSaveable { mutableStateOf("") }

    LaunchedEffect(Unit) { onRefreshStatus() }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 16.dp),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Spacer(modifier = Modifier.height(8.dp))

        // ── Header with status ──────────────────────────────────
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Text(
                text = "Computer Vision",
                fontWeight = FontWeight.Bold,
                fontSize = 18.sp,
                color = White
            )
            Text(
                text = state.visionStatus,
                fontSize = 11.sp,
                color = Gray300
            )
        }

        Spacer(modifier = Modifier.height(12.dp))

        // ── Camera controls ─────────────────────────────────────
        Card(
            modifier = Modifier.fillMaxWidth(),
            shape = RoundedCornerShape(12.dp),
            colors = CardDefaults.cardColors(containerColor = NexusCardDark)
        ) {
            Column(modifier = Modifier.padding(12.dp)) {
                // Camera selector row
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Text("Camera:", color = Gray300, fontSize = 12.sp)
                    Spacer(modifier = Modifier.width(8.dp))
                    // Camera dropdown
                    var expanded by remember { mutableStateOf(false) }
                    Box(modifier = Modifier.weight(1f)) {
                        OutlinedButton(
                            onClick = { expanded = true },
                            modifier = Modifier.fillMaxWidth(),
                            shape = RoundedCornerShape(8.dp),
                            colors = ButtonDefaults.outlinedButtonColors(contentColor = White)
                        ) {
                            Icon(Icons.Default.Videocam, null, Modifier.size(16.dp))
                            Spacer(modifier = Modifier.width(4.dp))
                            Text(state.selectedCameraId, fontSize = 12.sp, maxLines = 1)
                        }
                        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
                            state.cameraIds.forEach { camId ->
                                DropdownMenuItem(
                                    text = { Text(camId) },
                                    onClick = {
                                        onCameraSelected(camId)
                                        expanded = false
                                    }
                                )
                            }
                        }
                    }

                    Spacer(modifier = Modifier.width(8.dp))
                    // Preview toggle button
                    Button(
                        onClick = onTogglePreview,
                        colors = ButtonDefaults.buttonColors(
                            containerColor = if (state.isPreviewRunning) NexusError else NexusRed
                        ),
                        shape = RoundedCornerShape(8.dp),
                        contentPadding = PaddingValues(horizontal = 12.dp, vertical = 4.dp)
                    ) {
                        Icon(
                            if (state.isPreviewRunning) Icons.Default.Stop else Icons.Default.PlayArrow,
                            null, Modifier.size(16.dp)
                        )
                        Spacer(modifier = Modifier.width(4.dp))
                        Text(
                            if (state.isPreviewRunning) "Stop" else "Start",
                            fontSize = 12.sp
                        )
                    }

                    Spacer(modifier = Modifier.width(8.dp))
                    // Snapshot button
                    OutlinedButton(
                        onClick = onSnapshot,
                        shape = RoundedCornerShape(8.dp),
                        contentPadding = PaddingValues(horizontal = 8.dp, vertical = 4.dp),
                        colors = ButtonDefaults.outlinedButtonColors(contentColor = White)
                    ) {
                        Text("📸", fontSize = 16.sp)
                    }
                }

                Spacer(modifier = Modifier.height(8.dp))

                // FPS slider
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("FPS:", color = Gray300, fontSize = 11.sp)
                    Spacer(modifier = Modifier.width(8.dp))
                    Slider(
                        value = state.previewFps.toFloat(),
                        onValueChange = { onFpsChanged(it.toInt()) },
                        valueRange = 1f..15f,
                        steps = 13,
                        modifier = Modifier.weight(1f),
                        colors = SliderDefaults.colors(
                            thumbColor = NexusRed,
                            activeTrackColor = NexusRed
                        )
                    )
                    Text(
                        "${state.previewFps}",
                        color = White,
                        fontSize = 12.sp,
                        modifier = Modifier.width(24.dp),
                        textAlign = TextAlign.Center
                    )
                }
            }
        }

        Spacer(modifier = Modifier.height(12.dp))

        // ── Camera preview ──────────────────────────────────────
        Card(
            modifier = Modifier
                .fillMaxWidth()
                .height(280.dp),
            shape = RoundedCornerShape(16.dp),
            colors = CardDefaults.cardColors(containerColor = NexusCardDark)
        ) {
            Box(
                modifier = Modifier.fillMaxSize(),
                contentAlignment = Alignment.Center
            ) {
                val bitmap = state.previewBitmap
                if (bitmap != null) {
                    Image(
                        bitmap = bitmap.asImageBitmap(),
                        contentDescription = "Camera preview",
                        modifier = Modifier.fillMaxSize(),
                        contentScale = ContentScale.Fit
                    )
                } else {
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        Icon(
                            Icons.Default.Camera,
                            contentDescription = null,
                            modifier = Modifier.size(48.dp),
                            tint = Gray400.copy(alpha = 0.4f)
                        )
                        Spacer(modifier = Modifier.height(8.dp))
                        Text(
                            text = if (state.isPreviewRunning) "Connecting..." else "Start a camera preview",
                            color = Gray400,
                            fontSize = 13.sp
                        )
                    }
                }

                // Detection overlay (bottom-left)
                if (state.detectionsText.isNotBlank()) {
                    Surface(
                        modifier = Modifier
                            .align(Alignment.BottomStart)
                            .padding(8.dp),
                        shape = RoundedCornerShape(6.dp),
                        color = Color.Black.copy(alpha = 0.6f)
                    ) {
                        Text(
                            text = state.detectionsText,
                            color = NexusSuccess,
                            fontSize = 10.sp,
                            fontFamily = FontFamily.Monospace,
                            modifier = Modifier.padding(horizontal = 6.dp, vertical = 3.dp),
                            maxLines = 2
                        )
                    }
                }
            }
        }

        Spacer(modifier = Modifier.height(12.dp))

        // ── Search ──────────────────────────────────────────────
        Card(
            modifier = Modifier.fillMaxWidth(),
            shape = RoundedCornerShape(12.dp),
            colors = CardDefaults.cardColors(containerColor = NexusCardDark)
        ) {
            Row(
                modifier = Modifier.padding(8.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                OutlinedTextField(
                    value = searchQuery,
                    onValueChange = { searchQuery = it },
                    modifier = Modifier.weight(1f),
                    placeholder = { Text("e.g. 'is there a person'", color = Gray400, fontSize = 12.sp) },
                    textStyle = MaterialTheme.typography.bodyMedium.copy(color = White, fontSize = 13.sp),
                    singleLine = true,
                    colors = OutlinedTextFieldDefaults.colors(
                        focusedBorderColor = Color.Transparent,
                        unfocusedBorderColor = Color.Transparent,
                        focusedContainerColor = Color.Transparent,
                        unfocusedContainerColor = Color.Transparent
                    )
                )
                IconButton(onClick = {
                    if (searchQuery.isNotBlank()) onSearch(searchQuery)
                }) {
                    Icon(Icons.Default.Search, "Search", tint = NexusRed)
                }
            }
        }

        Spacer(modifier = Modifier.height(8.dp))

        // ── Locate ──────────────────────────────────────────────
        Card(
            modifier = Modifier.fillMaxWidth(),
            shape = RoundedCornerShape(12.dp),
            colors = CardDefaults.cardColors(containerColor = NexusCardDark)
        ) {
            Row(
                modifier = Modifier.padding(8.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                OutlinedTextField(
                    value = locateItem,
                    onValueChange = { locateItem = it },
                    modifier = Modifier.weight(1f),
                    placeholder = { Text("e.g. 'USB drive'", color = Gray400, fontSize = 12.sp) },
                    textStyle = MaterialTheme.typography.bodyMedium.copy(color = White, fontSize = 13.sp),
                    singleLine = true,
                    colors = OutlinedTextFieldDefaults.colors(
                        focusedBorderColor = Color.Transparent,
                        unfocusedBorderColor = Color.Transparent,
                        focusedContainerColor = Color.Transparent,
                        unfocusedContainerColor = Color.Transparent
                    )
                )
                Button(
                    onClick = { if (locateItem.isNotBlank()) onLocate(locateItem) },
                    colors = ButtonDefaults.buttonColors(containerColor = NexusSuccess),
                    shape = RoundedCornerShape(8.dp),
                    contentPadding = PaddingValues(horizontal = 12.dp, vertical = 4.dp)
                ) {
                    Text("Find", fontSize = 12.sp)
                }
            }
        }

        // ── Result text ────────────────────────────────────────
        if (state.visionResultText.isNotBlank()) {
            Spacer(modifier = Modifier.height(8.dp))
            Text(
                text = state.visionResultText,
                color = Color(state.visionResultColor),
                fontSize = 12.sp,
                modifier = Modifier
                    .fillMaxWidth()
                    .background(
                        NexusCardDark.copy(alpha = 0.5f),
                        RoundedCornerShape(8.dp)
                    )
                    .padding(12.dp)
            )
        }

        // ── MQTT / Server status ───────────────────────────────
        Spacer(modifier = Modifier.height(12.dp))
        Card(
            modifier = Modifier.fillMaxWidth(),
            shape = RoundedCornerShape(12.dp),
            colors = CardDefaults.cardColors(containerColor = NexusCardDark)
        ) {
            Column(modifier = Modifier.padding(12.dp)) {
                Text(
                    "Server Status",
                    fontWeight = FontWeight.SemiBold,
                    fontSize = 13.sp,
                    color = White
                )
                Spacer(modifier = Modifier.height(4.dp))
                val statusColor = if (state.serverConnected) NexusSuccess else NexusWarning
                Text(
                    "🖥  Server: ${state.serverUrl.ifBlank { "not configured" }}",
                    color = Gray300, fontSize = 11.sp
                )
                Text(
                    "📡 Connected: ${if (state.serverConnected) "Yes ✓" else "No"}",
                    color = statusColor, fontSize = 11.sp
                )
                Text(
                    "🌐 Devices: ${state.networkDeviceCount} | GPU: ${state.networkGpuCount} | Cameras: ${state.networkCameraCount}",
                    color = Gray300, fontSize = 11.sp
                )
                Text(
                    "📨 MQTT: ${if (state.mqttAvailable) "Available" else "Not installed"} • Connected: ${if (state.mqttConnected) "Yes" else "No"}",
                    color = Gray300, fontSize = 11.sp
                )
                Spacer(modifier = Modifier.height(8.dp))
                OutlinedButton(
                    onClick = onRefreshStatus,
                    modifier = Modifier.fillMaxWidth(),
                    shape = RoundedCornerShape(8.dp),
                    colors = ButtonDefaults.outlinedButtonColors(contentColor = NexusRed)
                ) {
                    Text("Refresh Server Status", fontSize = 12.sp)
                }
            }
        }

        Spacer(modifier = Modifier.height(24.dp))
    }
}
