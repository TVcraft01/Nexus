package com.nexus.app.service

import android.os.Binder

class NexusMeshBinder(private val service: NexusMeshService) : Binder() {
    fun getService(): NexusMeshService = service
}
