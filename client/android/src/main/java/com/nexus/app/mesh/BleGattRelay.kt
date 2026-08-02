package com.nexus.app.mesh

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import androidx.core.content.ContextCompat
import com.nexus.app.command.CommandResult
import com.nexus.app.command.ZeroLLMCommandEngine
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeout
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import kotlin.coroutines.resume

/**
 * BLE GATT relay for Nexus mesh nodes.
 *
 * Each Nexus node runs both a GATT server (to receive commands) and connects as
 * a GATT client to send commands. All payloads are encrypted with the peer's
 * stored AES key from [PeerTrustStore].
 */
@SuppressLint("MissingPermission")
class BleGattRelay(
    private val context: Context,
    private val nodeId: String,
    private val peerTrustStore: PeerTrustStore,
    private val commandEngine: ZeroLLMCommandEngine,
    private val serviceScope: CoroutineScope,
    private val serviceUuid: UUID,
    private val commandCharacteristicUuid: UUID,
    private val resultCharacteristicUuid: UUID
) {
    private val bluetoothManager by lazy { context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager }

    private var gattServer: BluetoothGattServer? = null

    private val clientConnections = ConcurrentHashMap<String, BluetoothGatt>()
    private val connectMutexes = ConcurrentHashMap<String, Mutex>()
    private val writeMutexes = ConcurrentHashMap<String, Mutex>()
    private val addressToNodeId = ConcurrentHashMap<String, String>()
    private val addressToPeerId = ConcurrentHashMap<String, String>()
    private val connectionMtu = ConcurrentHashMap<String, Int>()
    private val subscribedDevices = ConcurrentHashMap<String, MutableSet<String>>()
    private val pendingWriteContinuations = ConcurrentHashMap<String, CompletableDeferred<Boolean>>()
    private val pendingDescriptorContinuations = ConcurrentHashMap<String, CompletableDeferred<Boolean>>()
    private val pendingResultContinuations = ConcurrentHashMap<String, CompletableDeferred<String>>()

    fun mapAddressToNodeId(address: String, nodeId: String) {
        addressToNodeId[address] = nodeId
    }

    companion object {
        const val REQUEST_MTU = 512
        const val DEFAULT_MTU = 23
        val CCCD_UUID: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
    }

    // ---------- Server side ----------

    fun startServer() {
        if (!hasBluetoothPermissions()) return
        try {
            val server = bluetoothManager.openGattServer(context, gattServerCallback) ?: return
            gattServer = server

            val service = BluetoothGattService(serviceUuid, BluetoothGattService.SERVICE_TYPE_PRIMARY)

            val commandChar = BluetoothGattCharacteristic(
                commandCharacteristicUuid,
                BluetoothGattCharacteristic.PROPERTY_WRITE,
                BluetoothGattCharacteristic.PERMISSION_WRITE
            )
            service.addCharacteristic(commandChar)

            val resultChar = BluetoothGattCharacteristic(
                resultCharacteristicUuid,
                BluetoothGattCharacteristic.PROPERTY_NOTIFY or BluetoothGattCharacteristic.PROPERTY_READ,
                BluetoothGattCharacteristic.PERMISSION_READ
            )
            service.addCharacteristic(resultChar)

            server.addService(service)
            Log.i("BleGattRelay", "GATT server started")
        } catch (e: Exception) {
            Log.e("BleGattRelay", "Failed to start GATT server", e)
        }
    }

    fun stopServer() {
        try {
            gattServer?.close()
        } catch (_: Exception) { }
        gattServer = null
        clientConnections.values.forEach { try { it.close() } catch (_: Exception) { } }
        clientConnections.clear()
        subscribedDevices.clear()
        pendingWriteContinuations.values.forEach { it.cancel() }
        pendingWriteContinuations.clear()
        pendingDescriptorContinuations.values.forEach { it.cancel() }
        pendingDescriptorContinuations.clear()
        pendingResultContinuations.values.forEach { it.cancel() }
        pendingResultContinuations.clear()
    }

    // ---------- Client side ----------

    suspend fun relayCommand(peerId: String, targetDevice: BluetoothDevice, command: String): Result<String> {
        val key = peerTrustStore.getPeerKey(peerId)
        if (key == null) {
            Log.w("BleGattRelay", "No shared key for $peerId; pair first")
            return Result.failure(IllegalStateException("No shared key for $peerId"))
        }

        return try {
            val payload = MeshPayload(command = command).toJson().toByteArray(Charsets.UTF_8)
            val encrypted = MeshCrypto.encrypt(key, payload)
            val message = MeshMessage(
                senderId = nodeId,
                type = MeshMessageType.COMMAND,
                iv = encrypted.copyOfRange(0, 12),
                payload = encrypted.copyOfRange(12, encrypted.size)
            )
            val data = message.toJson().toByteArray(Charsets.UTF_8)

            val gatt = connect(targetDevice) ?: return Result.failure(
                IllegalStateException("Could not connect to ${targetDevice.address}")
            )
            val service = gatt.getService(serviceUuid)
            val commandChar = service?.getCharacteristic(commandCharacteristicUuid)
                ?: return Result.failure(IllegalStateException("Command characteristic missing on ${targetDevice.address}"))
            val resultChar = service.getCharacteristic(resultCharacteristicUuid)
                ?: return Result.failure(IllegalStateException("Result characteristic missing on ${targetDevice.address}"))

            addressToPeerId[gatt.device.address] = peerId

            // Enable notifications on the result characteristic before writing.
            enableNotifications(gatt, resultChar)

            val deferred = CompletableDeferred<String>()
            pendingResultContinuations[peerId] = deferred

            writeCharacteristic(gatt, commandChar, data)

            return try {
                withTimeout(15_000) {
                    val resultJson = deferred.await()
                    Result.success(resultJson)
                }
            } finally {
                pendingResultContinuations.remove(peerId)
            }
        } catch (e: Exception) {
            Log.e("BleGattRelay", "BLE relay failed", e)
            Result.failure(e)
        }
    }

    // ---------- Internals ----------

    private suspend fun connect(device: BluetoothDevice): BluetoothGatt? {
        if (!hasBluetoothPermissions()) return null

        val mutex = connectMutexes.getOrPut(device.address) { Mutex() }
        return mutex.withLock {
            try {
                val existing = clientConnections[device.address]
                if (existing != null) return@withLock existing
                doConnect(device)
            } finally {
                connectMutexes.remove(device.address)
            }
        }
    }

    private suspend fun doConnect(device: BluetoothDevice): BluetoothGatt? {
        return try {
            withTimeout(10_000) {
                suspendCancellableCoroutine<BluetoothGatt?> { continuation ->
                    val callback = object : BluetoothGattCallback() {
                        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
                            if (newState == BluetoothProfile.STATE_CONNECTED) {
                                gatt.requestMtu(REQUEST_MTU)
                            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                                clientConnections.remove(device.address)
                                connectionMtu.remove(device.address)
                                addressToPeerId.remove(device.address)?.let { disconnectedPeerId ->
                                    pendingResultContinuations.remove(disconnectedPeerId)?.cancel()
                                }
                                pendingWriteContinuations.remove(device.address)?.cancel()
                                pendingDescriptorContinuations.remove(device.address)?.cancel()
                                if (continuation.isActive) continuation.resume(null)
                            }
                        }

                        override fun onMtuChanged(gatt: BluetoothGatt, mtu: Int, status: Int) {
                            if (status == BluetoothGatt.GATT_SUCCESS) {
                                connectionMtu[gatt.device.address] = mtu
                            }
                            gatt.discoverServices()
                        }

                        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
                            if (continuation.isActive) {
                                clientConnections[device.address] = gatt
                                continuation.resume(gatt)
                            }
                        }

                        override fun onCharacteristicChanged(
                            gatt: BluetoothGatt,
                            characteristic: BluetoothGattCharacteristic,
                            value: ByteArray
                        ) {
                            handleResultNotification(characteristic, value)
                        }

                        @Suppress("DEPRECATION")
                        override fun onCharacteristicChanged(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
                            handleResultNotification(characteristic, characteristic.value)
                        }

                        @Suppress("DEPRECATION")
                        override fun onCharacteristicWrite(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, status: Int) {
                            pendingWriteContinuations[gatt.device.address]?.complete(status == BluetoothGatt.GATT_SUCCESS)
                        }

                        @Suppress("DEPRECATION")
                        override fun onDescriptorWrite(gatt: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) {
                            pendingDescriptorContinuations[gatt.device.address]?.complete(status == BluetoothGatt.GATT_SUCCESS)
                        }
                    }

                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        device.connectGatt(context, false, callback, android.bluetooth.BluetoothDevice.TRANSPORT_LE)
                    } else {
                        @Suppress("DEPRECATION")
                        device.connectGatt(context, false, callback)
                    }
                }
            }
        } catch (_: TimeoutCancellationException) {
            Log.w("BleGattRelay", "GATT connect timeout for ${device.address}")
            null
        }
    }

    private suspend fun enableNotifications(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
        val address = gatt.device.address
        gatt.setCharacteristicNotification(characteristic, true)
        val descriptor = characteristic.getDescriptor(CCCD_UUID) ?: return
        val deferred = CompletableDeferred<Boolean>()
        pendingDescriptorContinuations[address] = deferred
        val written = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            gatt.writeDescriptor(descriptor, BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE) == android.bluetooth.BluetoothStatusCodes.SUCCESS
        } else {
            @Suppress("DEPRECATION")
            descriptor.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
            @Suppress("DEPRECATION")
            gatt.writeDescriptor(descriptor)
            true
        }
        if (written) {
            try {
                val success = withTimeout(5_000) { deferred.await() }
                if (!success) {
                    throw IllegalStateException("CCCD write failed for $address")
                }
            } catch (e: Exception) {
                pendingDescriptorContinuations.remove(address)
                throw IllegalStateException("Failed to enable notifications for $address", e)
            }
        }
        pendingDescriptorContinuations.remove(address)
    }

    private fun handleResultNotification(characteristic: BluetoothGattCharacteristic, value: ByteArray?) {
        if (characteristic.uuid != resultCharacteristicUuid || value == null) return
        try {
            val message = MeshMessage.fromJson(String(value, Charsets.UTF_8))
            val peerId = message.senderId
            val key = peerTrustStore.getPeerKey(peerId) ?: return
            val ivAndCipher = message.iv + message.payload
            val plain = String(MeshCrypto.decrypt(key, ivAndCipher), Charsets.UTF_8)
            val payload = MeshPayload.fromJson(plain)
            pendingResultContinuations[peerId]?.complete(payload.result ?: "")
        } catch (e: Exception) {
            Log.e("BleGattRelay", "Failed to handle result notification", e)
        }
    }

    private suspend fun writeCharacteristic(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, data: ByteArray) {
        val address = gatt.device.address
        val mutex = writeMutexes.getOrPut(address) { Mutex() }
        mutex.withLock {
            val mtu = connectionMtu[address] ?: DEFAULT_MTU
            val maxWriteSize = (mtu - 3).coerceAtLeast(20)
            if (data.size > maxWriteSize) {
                throw IllegalStateException(
                    "BLE payload ${data.size} bytes exceeds negotiated MTU write size ($maxWriteSize). " +
                    "Reduce command length or request a larger MTU."
                )
            }
            val deferred = CompletableDeferred<Boolean>()
            pendingWriteContinuations[address] = deferred
            try {
                if (!writeBytes(gatt, characteristic, data)) {
                    throw IllegalStateException("BLE write rejected for $address")
                }
                if (!deferred.await()) {
                    throw IllegalStateException("BLE write failed for $address")
                }
            } finally {
                pendingWriteContinuations.remove(address)
            }
        }
    }

    private fun writeBytes(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, data: ByteArray): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            gatt.writeCharacteristic(characteristic, data, BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT) == android.bluetooth.BluetoothStatusCodes.SUCCESS
        } else {
            @Suppress("DEPRECATION")
            characteristic.value = data
            @Suppress("DEPRECATION")
            gatt.writeCharacteristic(characteristic)
            true
        }
    }

    private fun onCommandWrite(deviceAddress: String, value: ByteArray) {
        serviceScope.launch {
            try {
                val message = MeshMessage.fromJson(String(value, Charsets.UTF_8))
                val peerId = addressToNodeId[deviceAddress] ?: message.senderId
                val key = peerTrustStore.getPeerKey(peerId) ?: return@launch
                val ivAndCipher = message.iv + message.payload
                val plain = MeshCrypto.decrypt(key, ivAndCipher)
                val payload = MeshPayload.fromJson(String(plain, Charsets.UTF_8))

                when (message.type) {
                    MeshMessageType.COMMAND -> {
                        val result = commandEngine.executeCommand(payload.command ?: "")
                        Log.d("BleGattRelay", "Executed relayed command from $deviceAddress: ${result.message}")
                        sendResultToDevice(deviceAddress, peerId, result)
                    }
                    else -> {
                        Log.d("BleGattRelay", "Received ${message.type} from $deviceAddress")
                    }
                }
            } catch (e: Exception) {
                Log.e("BleGattRelay", "Failed to handle command write", e)
            }
        }
    }

    private fun sendResultToDevice(deviceAddress: String, peerId: String, result: CommandResult) {
        try {
            val key = peerTrustStore.getPeerKey(peerId) ?: return
            val payload = MeshPayload(result = result.message, success = result.success).toJson().toByteArray(Charsets.UTF_8)
            val encrypted = MeshCrypto.encrypt(key, payload)
            val message = MeshMessage(
                senderId = nodeId,
                type = MeshMessageType.RESULT,
                iv = encrypted.copyOfRange(0, 12),
                payload = encrypted.copyOfRange(12, encrypted.size)
            )
            val data = message.toJson().toByteArray(Charsets.UTF_8)

            val device = bluetoothManager.adapter?.getRemoteDevice(deviceAddress) ?: return
            notifyResult(device, data)
        } catch (e: Exception) {
            Log.e("BleGattRelay", "Failed to send result to $deviceAddress", e)
        }
    }

    private fun notifyResult(device: BluetoothDevice, data: ByteArray) {
        val server = gattServer ?: return
        val resultChar = server.getService(serviceUuid)?.getCharacteristic(resultCharacteristicUuid) ?: return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            server.notifyCharacteristicChanged(device, resultChar, false, data)
        } else {
            @Suppress("DEPRECATION")
            resultChar.value = data
            @Suppress("DEPRECATION")
            server.notifyCharacteristicChanged(device, resultChar, false)
        }
    }

    private fun hasBluetoothPermissions(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            ContextCompat.checkSelfPermission(context, Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED
        } else {
            true
        }
    }

    private val gattServerCallback = object : BluetoothGattServerCallback() {
        override fun onCharacteristicWriteRequest(
            device: BluetoothDevice?,
            requestId: Int,
            characteristic: BluetoothGattCharacteristic?,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray?
        ) {
            val address = device?.address ?: return
            val uuid = characteristic?.uuid ?: return
            val data = value ?: return

            if (uuid == commandCharacteristicUuid) {
                onCommandWrite(address, data)
            }

            if (responseNeeded) {
                gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, null)
            }
        }

        override fun onDescriptorWriteRequest(
            device: BluetoothDevice?,
            requestId: Int,
            descriptor: BluetoothGattDescriptor?,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray?
        ) {
            if (descriptor?.uuid == CCCD_UUID) {
                val enabled = value?.contentEquals(BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE) == true
                val set = subscribedDevices.getOrPut(device?.address ?: return) { ConcurrentHashMap.newKeySet() }
                if (enabled) set.add(device.address) else set.remove(device.address)
                if (responseNeeded) {
                    gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, null)
                }
            }
        }
    }
}
