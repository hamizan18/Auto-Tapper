package com.mijaenn.auto_clicker

/**
 * Perantara antara AutoClickerService dan MainActivity.
 * Service memanggil emit(); Activity mendaftarkan listener saat engine Flutter siap.
 */
object AutomationBridge {
    @Volatile
    var listener: ((status: String, data: Map<String, Any?>) -> Unit)? = null

    fun emit(status: String, data: Map<String, Any?> = emptyMap()) {
        listener?.invoke(status, data)
    }
}
