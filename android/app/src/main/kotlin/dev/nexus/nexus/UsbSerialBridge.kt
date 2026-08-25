package dev.nexus.nexus

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbManager
import android.util.Base64
import androidx.core.content.ContextCompat
import android.util.Log
import com.hoho.android.usbserial.driver.UsbSerialDriver
import com.hoho.android.usbserial.driver.UsbSerialPort
import com.hoho.android.usbserial.driver.UsbSerialProber
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.IOException
import java.util.concurrent.ConcurrentHashMap

/**
 * USB-OTG serial: lets the phone talk to microcontrollers (ESP32, …) plugged
 * in over USB, the same way the PC talks to them over /dev/ttyUSB*.
 *
 * Commands (MethodChannel "dev.nexus.nexus/usb_serial"):
 *   list               -> [{deviceId, name}]
 *   open {deviceId, baudRate} -> bool (may prompt the user for permission)
 *   write {deviceId, data}    -> bool (data is base64)
 *   close {deviceId}
 *
 * Events (EventChannel "dev.nexus.nexus/usb_serial_events"):
 *   {deviceId, data}        bytes read from the device (data is base64)
 *   {deviceId, disconnected}
 */
class UsbSerialBridge(private val activity: MainActivity) {
    private val TAG = "NexusUsbSerial"
    private val ACTION_USB_PERMISSION = "dev.nexus.nexus.USB_PERMISSION"

    private val usbManager: UsbManager =
        activity.getSystemService(Context.USB_SERVICE) as UsbManager

    private val ports = ConcurrentHashMap<Int, UsbSerialPort>()
    private val connections = ConcurrentHashMap<Int, android.hardware.usb.UsbDeviceConnection>()
    private val threads = ConcurrentHashMap<Int, Thread>()
    private val pendingOpens = ConcurrentHashMap<Int, PendingOpen>()

    private var eventSink: EventChannel.EventSink? = null
    private var permissionReceiver: BroadcastReceiver? = null

    fun registerChannels(
        method: MethodChannel,
        events: EventChannel,
    ) {
        method.setMethodCallHandler { call, result ->
            when (call.method) {
                "list" -> result.success(listDevices())
                "open" -> open(call, result)
                "write" -> result.success(write(call))
                "close" -> {
                    close(call.argument<Int>("deviceId") ?: -1)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
        events.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
                eventSink = sink
            }
            override fun onCancel(arguments: Any?) {
                eventSink = null
            }
        })
        registerPermissionReceiver()
    }

    private fun listDevices(): List<Map<String, Any>> {
        val out = mutableListOf<Map<String, Any>>()
        try {
            val prober = UsbSerialProber.getDefaultProber()
            for (driver in prober.findAllDrivers(usbManager)) {
                out.add(
                    mapOf(
                        "deviceId" to driver.device.deviceId,
                        "name" to (driver.device.productName ?: driver.device.deviceName ?: "USB device"),
                    )
                )
            }
        } catch (e: Exception) {
            Log.e(TAG, "list failed", e)
        }
        return out
    }

    private fun open(call: MethodCall, result: MethodChannel.Result) {
        val deviceId = call.argument<Int>("deviceId") ?: return result.success(false)
        val baud = call.argument<Int>("baudRate") ?: 115200
        if (ports.containsKey(deviceId)) {
            result.success(true)
            return
        }
        val driver = findDriver(deviceId)
        if (driver == null) {
            Log.w(TAG, "no driver for device $deviceId")
            result.success(false)
            return
        }
        if (!usbManager.hasPermission(driver.device)) {
            pendingOpens[deviceId] = PendingOpen(result, baud)
            val intent = PendingIntent.getBroadcast(
                activity,
                0,
                Intent(ACTION_USB_PERMISSION).apply { setPackage(activity.packageName) },
                PendingIntent.FLAG_IMMUTABLE
            )
            usbManager.requestPermission(driver.device, intent)
            return
        }
        openDriver(driver, baud, result)
    }

    private fun findDriver(deviceId: Int): UsbSerialDriver? {
        return try {
            UsbSerialProber.getDefaultProber()
                .findAllDrivers(usbManager)
                .firstOrNull { it.device.deviceId == deviceId }
        } catch (e: Exception) {
            Log.e(TAG, "findDriver failed", e)
            null
        }
    }

    private fun openDriver(
        driver: UsbSerialDriver,
        baud: Int,
        result: MethodChannel.Result,
    ) {
        val deviceId = driver.device.deviceId
        try {
            val connection = usbManager.openDevice(driver.device)
                ?: throw IOException("could not open USB connection")
            val port = driver.ports.firstOrNull()
                ?: throw IOException("no serial port on device")
            port.open(connection)
            port.setParameters(
                baud,
                UsbSerialPort.DATABITS_8,
                UsbSerialPort.STOPBITS_1,
                UsbSerialPort.PARITY_NONE
            )
            ports[deviceId] = port
            connections[deviceId] = connection
            startReader(deviceId, port)
            Log.i(TAG, "opened device $deviceId at $baud baud")
            result.success(true)
        } catch (e: Exception) {
            Log.e(TAG, "open failed for $deviceId", e)
            try { ports.remove(deviceId)?.close() } catch (_: Exception) {}
            result.success(false)
        }
    }

    private fun startReader(deviceId: Int, port: UsbSerialPort) {
        val thread = Thread {
            val buf = ByteArray(4096)
            while (!Thread.currentThread().isInterrupted) {
                try {
                    val len = port.read(buf, 100)
                    if (len > 0) {
                        val data = buf.copyOf(len)
                        eventSink?.success(
                            mapOf(
                                "deviceId" to deviceId,
                                "data" to Base64.encodeToString(data, Base64.NO_WRAP),
                            )
                        )
                    }
                } catch (e: Exception) {
                    break
                }
            }
            // Port dropped (unplugged, closed) — tell Dart.
            if (ports.containsKey(deviceId)) {
                eventSink?.success(mapOf("deviceId" to deviceId, "disconnected" to true))
            }
            close(deviceId)
        }
        thread.isDaemon = true
        threads[deviceId] = thread
        thread.start()
    }

    private fun write(call: MethodCall): Boolean {
        val deviceId = call.argument<Int>("deviceId") ?: return false
        val data = call.argument<String>("data") ?: return false
        val port = ports[deviceId] ?: return false
        return try {
            val bytes = Base64.decode(data, Base64.DEFAULT)
            port.write(bytes, 1000)
            true
        } catch (e: Exception) {
            Log.e(TAG, "write failed for $deviceId", e)
            false
        }
    }

    private fun close(deviceId: Int) {
        threads.remove(deviceId)?.interrupt()
        try { ports.remove(deviceId)?.close() } catch (_: Exception) {}
        try { connections.remove(deviceId)?.close() } catch (_: Exception) {}
    }

    private class PendingOpen(
        val result: MethodChannel.Result,
        val baud: Int,
    )

    private fun registerPermissionReceiver() {
        if (permissionReceiver != null) return
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                if (intent.action != ACTION_USB_PERMISSION) return
                val device: UsbDevice? = intent.getParcelableExtra(UsbManager.EXTRA_DEVICE)
                val granted = intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)
                val deviceId = device?.deviceId ?: return
                val pending = pendingOpens.remove(deviceId)
                if (!granted) {
                    Log.w(TAG, "USB permission denied for $deviceId")
                    pending?.result?.success(false)
                    return
                }
                val driver = findDriver(deviceId)
                if (driver == null) {
                    pending?.result?.success(false)
                    return
                }
                if (pending != null) {
                    openDriver(driver, pending.baud, pending.result)
                } else {
                    openDriver(driver, 115200, object : MethodChannel.Result {
                        override fun success(result: Any?) {}
                        override fun error(code: String, message: String?, details: Any?) {}
                        override fun notImplemented() {}
                    })
                }
            }
        }
        permissionReceiver = receiver
        activity.registerReceiver(receiver, IntentFilter(ACTION_USB_PERMISSION), ContextCompat.RECEIVER_NOT_EXPORTED)
    }
}
