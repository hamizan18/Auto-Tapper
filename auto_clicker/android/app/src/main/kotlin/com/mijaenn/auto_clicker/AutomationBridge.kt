package com.mijaenn.auto_clicker

object AutomationBridge {
    @Volatile
    var listener: ((status: String, data: Map<String, Any?>) -> Unit)? = null
    fun emit(status: String, data: Map<String, Any?> = emptyMap()) {
        listener?.invoke(status, data)
    }
}