package com.nexus.app.service

import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.BluetoothLeAdvertiser
import android.bluetooth.le.BluetoothLeScanner
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.ParcelUuid
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import com.nexus.app.NexusApplication
import com.nexus.app.R
import com.nexus.app.command.UserRulesRepository
import com.nexus.app.command.ZeroLLMCommandEngine
import com.nexus.app.mesh.BleGattRelay
import com.nexus.app.mesh.MeshCrypto
import com.nexus.app.mesh.MeshMessage
import com.nexus.app.mesh.MeshMessageType
import com.nexus.app.mesh.MeshNode
import com.nexus.app.mesh.MeshPayload
import com.nexus.app.mesh.PeerTrustStore
import com.nexus.app.mesh.TransportType
import com.nexus.app.ui.MainActivity
import com.nexus.app.voice.VoskModelManager
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import org.json.JSONObject
import java.io.BufferedReader
import java.io.InputStreamReader
import java.io.PrintWriter
import java.net.ServerSocket
import java.net.Socket
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean

@SuppressLint("MissingPermission")
class NexusMeshService : Service() {

    companion object {
        const val CHANNEL_ID = "nexus_mesh_channel"
        const val NOTIFICATION_ID = 1
        val NEXUS_SERVICE_UUID: UUID = UUID.fromString("0000aaaa-0000-1000-8000-00805f9b34fb")
        const val NSD_SERVICE_TYPE = "_nexus._tcp"
        const val TCP_BUFFER_SIZE = 2048
        // Vosk wake-word engine configuration.
        const val VOSK_SAMPLE_RATE = 16000
        const val VOSK_AUDIO_BUFFER_MS = 100

        // BLE GATT mesh relay UUIDs
        val NEXUS_GATT_SERVICE_UUID: UUID = UUID.fromString("0000bbbb-0000-1000-8000-00805f9b34fb")
        val NEXUS_GATT_COMMAND_UUID: UUID = UUID.fromString("0000cccc-0000-1000-8000-00805f9b34fb")
        val NEXUS_GATT_RESULT_UUID: UUID = UUID.fromString("0000dddd-0000-1000-8000-00805f9b34fb")
    }

    private val binder = NexusMeshBinder(this)

    private val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    private val _discoveredNodes = MutableStateFlow<Map<String, MeshNode>>(emptyMap())
    val discoveredNodes: StateFlow<Map<String, MeshNode>> = _discoveredNodes.asStateFlow()

    private val bluetoothManager by lazy { getSystemService(BluetoothManager::class.java) }
    private val nsdManager by lazy { getSystemService(Context.NSD_SERVICE) as NsdManager }

    private var bluetoothAdvertiser: BluetoothLeAdvertiser? = null
    private var bluetoothScanner: BluetoothLeScanner? = null
    private var advertiseCallback: AdvertiseCallback? = null
    private var scanCallback: ScanCallback? = null
    private var nsdRegistrationListener: NsdManager.RegistrationListener? = null
    private var nsdDiscoveryListener: NsdManager.DiscoveryListener? = null
    private var serverSocket: ServerSocket? = null

    val nodeId by lazy {
        val androidId = android.provider.Settings.Secure.getString(contentResolver, android.provider.Settings.Secure.ANDROID_ID) ?: UUID.randomUUID().toString()
        // Keep BLE advertised payload small: first 6 bytes of stable ID hash.
        "nexus-${androidId.hashCode().toUInt().toString(radix = 16).padStart(8, '0').take(8)}"
    }
    val nodeName by lazy { "${Build.MANUFACTURER} ${Build.MODEL}" }

    private val activeResolveListeners = ConcurrentHashMap<String, NsdManager.ResolveListener>()

    private val meshDiscoveryStarted = AtomicBoolean(false)

    private val peerTrustStore by lazy { PeerTrustStore(this) }
    private var bleGattRelay: BleGattRelay? = null

    // --- Wake word (Vosk) ---
    private val _wakeEvent = MutableSharedFlow<Unit>(extraBufferCapacity = 1)
    val wakeEvent: SharedFlow<Unit> = _wakeEvent.asSharedFlow()

    private val voskModelManager by lazy { VoskModelManager.getInstance(this) }
    private var wakeWordEnabled = false
    private var audioRecord: android.media.AudioRecord? = null
    private var voskRecognizer: org.vosk.Recognizer? = null
    private var voskModel: org.vosk.Model? = null
    @Volatile
    private var isListeningForWake = false

    private val commandEngine by lazy {
        val app = applicationContext as NexusApplication
        ZeroLLMCommandEngine(
            app,
            UserRulesRepository(app, app.database),
            app.hardwareManager,
            app.database.noteDao(),
            app.learningRepository
        )
    }

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startForeground()
        startMeshDiscovery()
        if (intent?.action == TestPairingReceiver.ACTION_SERVICE_PAIR) {
            val peerId = intent.getStringExtra(TestPairingReceiver.EXTRA_PEER_ID) ?: ""
            val pin = intent.getStringExtra(TestPairingReceiver.EXTRA_PIN) ?: ""
            if (peerId.isNotBlank() && pin.isNotBlank()) {
                Log.i("NexusMeshService", "Auto-pairing with test peer $peerId")
                serviceScope.launch {
                    pairWithNode(peerId, pin)
                }
            }
        }
        return START_STICKY
    }

    fun setWakeWordEnabled(enabled: Boolean) {
        wakeWordEnabled = enabled
        if (enabled) {
            // Re-assert the foreground service type so the microphone type is
            // active once RECORD_AUDIO has been granted.
            startForeground()
            startVoskWakeWord()
        } else {
            stopVoskWakeWord()
        }
    }

    private fun startVoskWakeWord() {
        if (!PermissionChecker.hasRecordAudioPermission { permission ->
                ContextCompat.checkSelfPermission(this, permission)
            }) {
            Log.w("NexusMeshService", "RECORD_AUDIO not granted; cannot start wake-word listener.")
            return
        }
        if (isListeningForWake) return
        serviceScope.launch(Dispatchers.IO) {
            try {
                val lang = voskModelManager.getActiveLanguage()
                val ready = voskModelManager.ensureModel(lang)
                if (!ready) {
                    Log.w("NexusMeshService", "Vosk model for '$lang' is not ready. Ensure the bundled English model exists or download a language.")
                    return@launch
                }
                val modelDir = voskModelManager.activeModelDirectory
                val model = org.vosk.Model(modelDir.absolutePath)
                voskModel = model
                // Use a free-form recognizer instead of a strict grammar. A grammar
                // with only the wake phrase is too brittle for accents and noise.
                val recognizer = org.vosk.Recognizer(model, VOSK_SAMPLE_RATE.toFloat())
                voskRecognizer = recognizer
                isListeningForWake = true
                startAudioRecordLoop(recognizer)
                updateNotification("BLE + NSD mesh active | Wake-word listening ($lang)")
            } catch (e: Exception) {
                Log.e("NexusMeshService", "Failed to start Vosk wake-word listener", e)
                stopVoskWakeWord()
            }
        }
    }

    private fun stopVoskWakeWord() {
        isListeningForWake = false
        try {
            audioRecord?.stop()
            audioRecord?.release()
        } catch (_: Exception) { }
        audioRecord = null
        try {
            voskRecognizer?.close()
        } catch (_: Exception) { }
        voskRecognizer = null
        try {
            voskModel?.close()
        } catch (_: Exception) { }
        voskModel = null
        updateNotification("BLE + NSD mesh active")
    }

    private fun startAudioRecordLoop(recognizer: org.vosk.Recognizer) {
        try {
            val bufferSizeBytes = android.media.AudioRecord.getMinBufferSize(
                VOSK_SAMPLE_RATE,
                android.media.AudioFormat.CHANNEL_IN_MONO,
                android.media.AudioFormat.ENCODING_PCM_16BIT
            ).coerceAtLeast(VOSK_SAMPLE_RATE * VOSK_AUDIO_BUFFER_MS / 1000 * 2)

            val record = android.media.AudioRecord(
                android.media.MediaRecorder.AudioSource.MIC,
                VOSK_SAMPLE_RATE,
                android.media.AudioFormat.CHANNEL_IN_MONO,
                android.media.AudioFormat.ENCODING_PCM_16BIT,
                bufferSizeBytes
            )
            audioRecord = record
            record.startRecording()

            val buffer = ShortArray(bufferSizeBytes / 2)
            while (isListeningForWake) {
                val read = record.read(buffer, 0, buffer.size)
                if (read > 0) {
                    val accepted = recognizer.acceptWaveForm(buffer, read)
                    val resultJson = if (accepted) recognizer.result else recognizer.partialResult
                    if (containsWakePhrase(resultJson, voskModelManager.getActiveLanguage())) {
                        Log.d("NexusMeshService", "Vosk wake-word detected: $resultJson")
                        _wakeEvent.tryEmit(Unit)
                    }
                }
            }
            try {
                record.stop()
                record.release()
            } catch (_: Exception) { }
        } catch (e: Exception) {
            Log.e("NexusMeshService", "AudioRecord loop failed", e)
        }
    }

    private fun containsWakePhrase(resultJson: String, language: String): Boolean {
        return try {
            val json = org.json.JSONObject(resultJson)
            val text = json.optString("partial", json.optString("text", "")).lowercase()
                .replace("[\\p{P}]".toRegex(), "")
                .trim()

            val (primary, fallback) = when (language) {
                "fr" -> "salut nexus" to "nexus"
                "es" -> "hola nexus" to "nexus"
                "de" -> "hallo nexus" to "nexus"
                "it" -> "ciao nexus" to "nexus"
                "pt" -> "olá nexus" to "nexus"
                "ru" -> "привет nexus" to "nexus"
                "zh" -> "你好 nexus" to "nexus"
                else -> "hey nexus" to "nexus"
            }

            text.contains(primary) || text.contains(fallback)
        } catch (_: Exception) {
            false
        }
    }

    override fun onBind(intent: Intent): IBinder? = binder

    override fun onDestroy() {
        super.onDestroy()
        stopVoskWakeWord()
        stopMeshDiscovery()
        serviceScope.cancel()
    }

    private fun startForeground() {
        val notification = buildNotification("BLE + NSD mesh active")

        val hasRecordAudio = PermissionChecker.hasRecordAudioPermission { permission ->
            ContextCompat.checkSelfPermission(this, permission)
        }
        val hasBluetooth = PermissionChecker.hasBluetoothPermission(Build.VERSION.SDK_INT) { permission ->
            ContextCompat.checkSelfPermission(this, permission)
        }

        val foregroundType = ForegroundServiceTypeResolver.resolve(
            Build.VERSION.SDK_INT, hasBluetooth, hasRecordAudio
        )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, notification, foregroundType)
        } else {
            @Suppress("DEPRECATION")
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun updateNotification(text: String) {
        val notification = buildNotification(text)
        val manager = getSystemService(NotificationManager::class.java)
        manager?.notify(NOTIFICATION_ID, notification)
    }

    private fun buildNotification(contentText: String): Notification {
        val intent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            intent,
            PendingIntent.FLAG_IMMUTABLE
        )

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Nexus Mesh Engine")
            .setContentText(contentText)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .build()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Nexus Mesh Engine",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Maintains cross-device handoff and wearable sync hooks."
            }
            getSystemService(NotificationManager::class.java)?.createNotificationChannel(channel)
        }
    }

    private fun startMeshDiscovery() {
        if (!meshDiscoveryStarted.compareAndSet(false, true)) return
        startTcpServer()
        startBleAdvertising()
        startBleScanning()
        startNsdService()
        startNsdDiscovery()
        startBleGattRelay()
    }

    private fun stopMeshDiscovery() {
        if (!meshDiscoveryStarted.compareAndSet(true, false)) return
        stopBleAdvertising()
        stopBleScanning()
        stopNsdService()
        stopNsdDiscovery()
        stopTcpServer()
        stopBleGattRelay()
    }

    private fun startBleGattRelay() {
        try {
            val relay = BleGattRelay(
                this,
                nodeId,
                peerTrustStore,
                commandEngine,
                serviceScope,
                NEXUS_GATT_SERVICE_UUID,
                NEXUS_GATT_COMMAND_UUID,
                NEXUS_GATT_RESULT_UUID
            )
            relay.startServer()
            bleGattRelay = relay
        } catch (e: Exception) {
            Log.e("NexusMeshService", "Failed to start BLE GATT relay", e)
        }
    }

    private fun stopBleGattRelay() {
        bleGattRelay?.stopServer()
        bleGattRelay = null
    }

    // --- BLE Advertising ---

    private fun startBleAdvertising() {
        val adapter = bluetoothManager?.adapter ?: return
        if (!adapter.isEnabled) {
            updateNotification("Bluetooth disabled")
            return
        }
        bluetoothAdvertiser = adapter.bluetoothLeAdvertiser
        val pUuid = ParcelUuid(NEXUS_SERVICE_UUID)
        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_POWER)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_LOW)
            .setConnectable(true)
            .build()
        val data = AdvertiseData.Builder()
            .addServiceUuid(pUuid)
            .addServiceData(pUuid, nodeId.toByteArray(Charsets.UTF_8))
            .setIncludeDeviceName(false)
            .build()

        advertiseCallback = object : AdvertiseCallback() {
            override fun onStartSuccess(settingsInEffect: AdvertiseSettings?) {
                updateNotification("BLE advertising + NSD discovery active")
            }
            override fun onStartFailure(errorCode: Int) {
                updateNotification("BLE advertise failed: $errorCode")
            }
        }
        try {
            bluetoothAdvertiser?.startAdvertising(settings, data, advertiseCallback)
        } catch (e: SecurityException) {
            updateNotification("BLE advertise permission denied")
        }
    }

    private fun stopBleAdvertising() {
        advertiseCallback?.let {
            try {
                bluetoothAdvertiser?.stopAdvertising(it)
            } catch (_: SecurityException) { }
        }
        advertiseCallback = null
    }

    // --- BLE Scanning ---

    private fun startBleScanning() {
        val adapter = bluetoothManager?.adapter ?: return
        if (!adapter.isEnabled) return
        bluetoothScanner = adapter.bluetoothLeScanner
        val filter = ScanFilter.Builder()
            .setServiceUuid(ParcelUuid(NEXUS_SERVICE_UUID))
            .build()
        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_POWER)
            .build()

        scanCallback = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult) {
                handleBleScanResult(result)
            }
            override fun onBatchScanResults(results: MutableList<ScanResult>) {
                results.forEach { handleBleScanResult(it) }
            }
            override fun onScanFailed(errorCode: Int) {
                updateNotification("BLE scan failed: $errorCode")
            }
        }
        try {
            bluetoothScanner?.startScan(listOf(filter), settings, scanCallback)
        } catch (e: SecurityException) {
            updateNotification("BLE scan permission denied")
        }
    }

    private fun stopBleScanning() {
        scanCallback?.let {
            try {
                bluetoothScanner?.stopScan(scanCallback)
            } catch (_: SecurityException) { }
        }
        scanCallback = null
    }

    private fun handleBleScanResult(result: ScanResult) {
        val device = result.device
        val address = device.address ?: return
        val record = result.scanRecord ?: return
        val data = record.serviceData?.get(ParcelUuid(NEXUS_SERVICE_UUID))
        val remoteId = data?.toString(Charsets.UTF_8) ?: address
        val name = device.name ?: "Nexus-BLE-$remoteId"
        bleGattRelay?.mapAddressToNodeId(address, remoteId)
        upsertNode(
            MeshNode(
                id = remoteId,
                name = name,
                address = address,
                transport = TransportType.BLE,
                lastSeen = System.currentTimeMillis(),
                isPaired = peerTrustStore.isPaired(remoteId)
            )
        )
    }

    // --- NSD ---

    private fun startNsdService() {
        try {
            serverSocket = ServerSocket(0)
        } catch (e: Exception) {
            updateNotification("NSD server socket failed")
            return
        }
        val port = serverSocket?.localPort ?: return

        val serviceInfo = NsdServiceInfo().apply {
            serviceName = "${nodeName}-${nodeId}".take(50)
            serviceType = NSD_SERVICE_TYPE
            setPort(port)
        }

        nsdRegistrationListener = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(serviceInfo: NsdServiceInfo) {}
            override fun onRegistrationFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {}
            override fun onServiceUnregistered(serviceInfo: NsdServiceInfo) {}
            override fun onUnregistrationFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {}
        }

        nsdManager.registerService(serviceInfo, NsdManager.PROTOCOL_DNS_SD, nsdRegistrationListener!!)
        startTcpAcceptLoop()
    }

    private fun stopNsdService() {
        nsdRegistrationListener?.let { nsdManager.unregisterService(it) }
        nsdRegistrationListener = null
    }

    private fun startNsdDiscovery() {
        nsdDiscoveryListener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) {}
            override fun onDiscoveryStopped(serviceType: String) {}
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {}
            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {}
            override fun onServiceFound(serviceInfo: NsdServiceInfo) {
                handleNsdServiceFound(serviceInfo)
            }
            override fun onServiceLost(serviceInfo: NsdServiceInfo) {}
        }
        nsdManager.discoverServices(NSD_SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, nsdDiscoveryListener!!)
    }

    private fun stopNsdDiscovery() {
        nsdDiscoveryListener?.let { nsdManager.stopServiceDiscovery(it) }
        nsdDiscoveryListener = null
    }

    private fun handleNsdServiceFound(serviceInfo: NsdServiceInfo) {
        if (serviceInfo.serviceName.contains(nodeId)) return
        val key = "nsd-${serviceInfo.serviceName}"
        val listener = object : NsdManager.ResolveListener {
            override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                activeResolveListeners.remove(key)
            }
            override fun onServiceResolved(serviceInfo: NsdServiceInfo) {
                activeResolveListeners.remove(key)
                val address = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                    serviceInfo.hostAddresses.firstOrNull()?.hostAddress
                } else {
                    @Suppress("DEPRECATION")
                    serviceInfo.host?.hostAddress
                }
                upsertNode(
                    MeshNode(
                        id = serviceInfo.serviceName,
                        name = serviceInfo.serviceName,
                        address = address ?: "",
                        port = serviceInfo.port,
                        transport = TransportType.WIFI_NSD,
                        lastSeen = System.currentTimeMillis()
                    )
                )
            }
        }
        if (activeResolveListeners.putIfAbsent(key, listener) != null) return
        resolveServiceCompat(serviceInfo, listener)
    }

    @Suppress("DEPRECATION")
    private fun resolveServiceCompat(serviceInfo: NsdServiceInfo, listener: NsdManager.ResolveListener) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            nsdManager.resolveService(serviceInfo, ContextCompat.getMainExecutor(this), listener)
        } else {
            nsdManager.resolveService(serviceInfo, listener)
        }
    }

    // --- TCP Command Relay ---

    private fun startTcpServer() {
        // ServerSocket is created in startNsdService; this starts the accept loop.
    }

    private fun stopTcpServer() {
        try {
            serverSocket?.close()
        } catch (_: Exception) { }
        serverSocket = null
    }

    private fun startTcpAcceptLoop() {
        serviceScope.launch {
            while (true) {
                val socket = try {
                    serverSocket?.accept()
                } catch (e: Exception) {
                    break
                } ?: break
                handleClient(socket)
            }
        }
    }

    private fun handleClient(socket: Socket) {
        serviceScope.launch {
            try {
                socket.use { s ->
                    val reader = BufferedReader(InputStreamReader(s.getInputStream()))
                    val payload = reader.readLine() ?: return@launch
                    handleRelayPayload(payload, socket)
                }
            } catch (e: Exception) {
                Log.w("NexusMeshService", "Client handling failed", e)
            }
        }
    }

    private suspend fun handleRelayPayload(payload: String, socket: Socket) {
        // Try to parse as encrypted MeshMessage first.
        try {
            val message = MeshMessage.fromJson(payload)
            val key = peerTrustStore.getPeerKey(message.senderId)
            if (key != null) {
                val ivAndCipher = message.iv + message.payload
                val plain = String(MeshCrypto.decrypt(key, ivAndCipher), Charsets.UTF_8)
                val meshPayload = MeshPayload.fromJson(plain)
                Log.d("NexusMeshService", "Encrypted relayed command from ${message.senderId}: ${meshPayload.command}")
                val result = commandEngine.executeCommand(meshPayload.command ?: "")
                sendResult(socket, message.senderId, result.success, result.message)
                return
            }
        } catch (_: Exception) { /* fall through to legacy raw JSON */ }

        try {
            val json = JSONObject(payload)
            val command = json.optString("cmd")
            val sender = json.optString("senderId", "unknown")
            if (command.isNotBlank()) {
                Log.d("NexusMeshService", "Legacy relayed command from $sender: $command")
                val result = commandEngine.executeCommand(command)
                sendResult(socket, nodeId, result.success, result.message)
            }
        } catch (e: Exception) {
            Log.e("NexusMeshService", "Failed to parse relay payload", e)
        }
    }

    private fun sendResult(socket: Socket, senderId: String, ok: Boolean, message: String) {
        try {
            val key = peerTrustStore.getPeerKey(senderId)
            val response = if (key != null) {
                val encrypted = MeshCrypto.encrypt(key, MeshPayload(result = message, success = ok).toJson().toByteArray(Charsets.UTF_8))
                val responseMessage = MeshMessage(
                    senderId = nodeId,
                    type = MeshMessageType.RESULT,
                    iv = encrypted.copyOfRange(0, 12),
                    payload = encrypted.copyOfRange(12, encrypted.size)
                )
                responseMessage.toJson()
            } else {
                JSONObject().apply {
                    put("ok", ok)
                    put("result", message)
                    put("senderId", nodeId)
                }.toString()
            }
            val writer = PrintWriter(socket.getOutputStream(), true)
            writer.println(response)
        } catch (e: Exception) {
            Log.e("NexusMeshService", "Failed to send relay result", e)
        }
    }

    fun pairWithNode(peerId: String, pin: String): Boolean {
        // Derive a symmetric salt from both node IDs so the initiator and the
        // target compute the exact same shared key without caring who is which.
        val symmetricId = listOf(nodeId, peerId).sorted().joinToString("|")
        val salt = MeshCrypto.saltForNodeId(symmetricId)
        val key = MeshCrypto.deriveKeyFromPin(pin, salt)
        peerTrustStore.storePeerKey(peerId, key)
        return true
    }

    fun unpairNode(peerId: String) {
        peerTrustStore.removePeer(peerId)
    }

    fun isPaired(peerId: String): Boolean = peerTrustStore.isPaired(peerId)

    fun relayCommand(target: MeshNode, command: String): Boolean {
        return when (target.transport) {
            TransportType.WIFI_NSD -> relayOverTcp(target, command)
            TransportType.BLE -> relayOverBle(target, command)
        }
    }

    private fun relayOverBle(target: MeshNode, command: String): Boolean {
        if (!peerTrustStore.isPaired(target.id)) {
            Log.w("NexusMeshService", "Cannot relay to ${target.id} over BLE: not paired")
            return false
        }
        val bluetoothAdapter = bluetoothManager?.adapter ?: return false
        val device = try {
            bluetoothAdapter.getRemoteDevice(target.address)
        } catch (e: IllegalArgumentException) {
            Log.w("NexusMeshService", "Invalid BLE address for ${target.id}", e)
            return false
        }
        val relay = bleGattRelay ?: return false
        relay.mapAddressToNodeId(target.address, target.id)
        serviceScope.launch {
            val result = relay.relayCommand(target.id, device, command)
            result.onSuccess { response ->
                Log.d("NexusMeshService", "BLE relay result from ${target.id}: $response")
            }.onFailure { error ->
                Log.w("NexusMeshService", "BLE relay to ${target.id} failed: ${error.message}")
            }
        }
        return true
    }

    private fun relayOverTcp(target: MeshNode, command: String): Boolean {
        val port = target.port ?: return false
        return try {
            Socket(target.address, port).use { socket ->
                val writer = PrintWriter(socket.getOutputStream(), true)
                val key = peerTrustStore.getPeerKey(target.id)
                val payload = if (key != null) {
                    val encrypted = MeshCrypto.encrypt(key, MeshPayload(command = command).toJson().toByteArray(Charsets.UTF_8))
                    val message = MeshMessage(
                        senderId = nodeId,
                        type = MeshMessageType.COMMAND,
                        iv = encrypted.copyOfRange(0, 12),
                        payload = encrypted.copyOfRange(12, encrypted.size)
                    )
                    message.toJson()
                } else {
                    JSONObject().apply {
                        put("cmd", command)
                        put("senderId", nodeId)
                    }.toString()
                }
                writer.println(payload)
            }
            true
        } catch (e: Exception) {
            false
        }
    }

    private fun upsertNode(node: MeshNode) {
        _discoveredNodes.update { current ->
            current.toMutableMap().apply { put(node.id, node) }
        }
    }

    // --- Legacy hooks (kept for compatibility) ---

    fun scanBlePresence(): String {
        val adapter = bluetoothManager?.adapter
        if (adapter == null) return "BluetoothManager unavailable"
        if (!adapter.isEnabled) return "Bluetooth disabled"
        return "BLE mesh discovery active (${discoveredNodes.value.size} nodes)"
    }

    fun requestAudioHandoff(deviceId: String): String {
        return "Audio handoff hook requested for $deviceId"
    }

    fun syncHealthData(): String {
        return "Health/wearable sync hook executed."
    }
}
