package com.mijaenn.auto_clicker

import android.content.Intent
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    companion object {
        // Harus identik dengan nama channel di lib/automation_channel.dart
        const val CHANNEL_NAME = "com.example.auto_clicker/automation"
    }

    private var channel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_NAME)
        channel = ch

        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "isServiceEnabled" -> result.success(AutoClickerService.instance != null)

                "openAccessibilitySettings" -> {
                    startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
                    result.success(null)
                }

                "getStatus" -> {
                    val svc = AutoClickerService.instance
                    result.success(
                        mapOf(
                            "serviceEnabled" to (svc != null),
                            "state" to (svc?.state?.name?.lowercase() ?: "idle"),
                            "executed" to (svc?.executedCount ?: 0)
                        )
                    )
                }

                "startAutomation" -> {
                    val svc = AutoClickerService.instance
                    if (svc == null) {
                        result.error("SERVICE_NOT_ENABLED", "Layanan aksesibilitas belum aktif", null)
                    } else {
                        try {
                            svc.startAutomation(parseConfig(call))
                            result.success(null)
                        } catch (e: IllegalArgumentException) {
                            result.error("INVALID_ARGUMENT", e.message, null)
                        }
                    }
                }

                "pauseAutomation" -> withService(result) { it.pauseAutomation() }
                "resumeAutomation" -> withService(result) { it.resumeAutomation() }
                "stopAutomation" -> withService(result) { it.stopAutomation() }

                else -> result.notImplemented()
            }
        } // <-- tutup setMethodCallHandler

        // Teruskan event dari service ke Dart (wajib di Main thread)
        AutomationBridge.listener = { status, data ->
            runOnUiThread {
                channel?.invokeMethod(
                    "onStatusChanged",
                    mapOf("status" to status, "data" to data)
                )
            }
        }
    } // <-- tutup configureFlutterEngine

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        AutomationBridge.listener = null
        channel?.setMethodCallHandler(null)
        channel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    // Fungsi-fungsi berikut harus berada DI DALAM class MainActivity.

    private fun withService(
        result: MethodChannel.Result,
        block: (AutoClickerService) -> Unit
    ) {
        val svc = AutoClickerService.instance
        if (svc == null) {
            result.error("SERVICE_NOT_ENABLED", "Layanan aksesibilitas belum aktif", null)
        } else {
            block(svc)
            result.success(null)
        }
    }

    private fun parseConfig(call: MethodCall): AutomationConfig {
        val type = when (call.argument<String>("actionType")) {
            "click" -> ActionType.CLICK
            "scroll" -> ActionType.SCROLL
            else -> throw IllegalArgumentException("actionType tidak dikenal")
        }

        fun intArg(key: String): Int =
            call.argument<Int>(key)
                ?: throw IllegalArgumentException("Argumen '$key' wajib diisi")

        return AutomationConfig(
            actionType = type,
            x = intArg("x"),
            y = intArg("y"),
            scrollDistance = intArg("scrollDistance"),
            scrollDurationMs = intArg("scrollDurationMs").toLong(),
            intervalMs = intArg("intervalMs").toLong(),
            loopCount = intArg("loopCount")
        )
    }
} // <-- tutup class MainActivity
