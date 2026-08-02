package com.nexus.app.mesh

enum class TransportType {
    BLE, WIFI_NSD
}

data class MeshNode(
    val id: String,
    val name: String,
    val address: String,
    val port: Int? = null,
    val transport: TransportType,
    val lastSeen: Long = System.currentTimeMillis(),
    val isPaired: Boolean = false
) {
    val isReachable: Boolean
        get() = (System.currentTimeMillis() - lastSeen) < 60_000

    fun copyWithPaired(paired: Boolean) = copy(isPaired = paired, lastSeen = System.currentTimeMillis())
}
