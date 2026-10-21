package com.mijaenn.auto_clicker

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.content.Intent
import android.graphics.Path
import android.util.Log
import android.view.accessibility.AccessibilityEvent
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlin.coroutines.resume

enum class ActionType { CLICK, SCROLL }

enum class AutomationState { IDLE, RUNNING, PAUSED }

data class AutomationConfig(
    val actionType: ActionType,
    val x: Int,
    val y: Int,                    // klik: titik ketuk | scroll: titik awal swipe (yStart)
    val scrollDistance: Int,       // jarak swipe (px), dipakai mode scroll
    val scrollDurationMs: Long,    // durasi swipe (ms)
    val intervalMs: Long,          // jeda antar aksi (ms)
    val loopCount: Int             // 0 = tak terbatas
)

class AutoClickerService : AccessibilityService() {

    companion object {
        private const val TAG = "AutoClickerService"
        private const val CLICK_DURATION_MS = 50L
        private const val MIN_INTERVAL_MS = 100L

        /** Referensi service aktif; null jika belum/tidak diaktifkan pengguna. */
        @Volatile
        var instance: AutoClickerService? = null
            private set
    }

    // Scope milik service. SupervisorJob: satu error anak tidak mematikan seluruh scope.
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private var loopJob: Job? = null

    @Volatile var state: AutomationState = AutomationState.IDLE
        private set
    @Volatile var executedCount: Int = 0
        private set
    @Volatile private var paused = false

    // ───────────── Lifecycle ─────────────

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
        Log.i(TAG, "Service terhubung")
        AutomationBridge.emit("serviceConnected")
    }

    // Kita tidak membaca event layar; cukup dikosongkan.
    override fun onAccessibilityEvent(event: AccessibilityEvent?) = Unit

    // Dipanggil sistem bila layanan "diinterupsi" (mis. fokus berpindah). Hentikan dengan aman.
    override fun onInterrupt() {
        stopAutomation()
    }

    override fun onUnbind(intent: Intent?): Boolean {
        stopAutomation()
        instance = null
        AutomationBridge.emit("serviceDisconnected")
        return super.onUnbind(intent)
    }

    override fun onDestroy() {
        scope.cancel()          // bersihkan semua coroutine → tidak ada kebocoran
        instance = null
        super.onDestroy()
    }

    // ───────────── API publik (dipanggil dari MainActivity di Main thread) ─────────────

    fun startAutomation(config: AutomationConfig) {
        validate(config)                       // melempar IllegalArgumentException jika tidak valid
        loopJob?.cancel()                      // pastikan tidak ada loop ganda
        executedCount = 0
        paused = false
        state = AutomationState.RUNNING
        AutomationBridge.emit("running")

        loopJob = scope.launch { runLoop(config) }   // berjalan di Dispatchers.Default
    }

    fun pauseAutomation() {
        if (state != AutomationState.RUNNING) return
        paused = true
        state = AutomationState.PAUSED
        AutomationBridge.emit("paused")
    }

    fun resumeAutomation() {
        if (state != AutomationState.PAUSED) return
        paused = false
        state = AutomationState.RUNNING
        AutomationBridge.emit("running")
    }

    fun stopAutomation() {
        loopJob?.cancel()
        loopJob = null
        paused = false
        if (state != AutomationState.IDLE) {
            state = AutomationState.IDLE
            AutomationBridge.emit("stopped", mapOf("executed" to executedCount))
        }
    }

    // ───────────── Loop otomasi (berjalan di thread background) ─────────────

    private suspend fun runLoop(config: AutomationConfig) {
        try {
            while (true) {
                if (config.loopCount > 0 && executedCount >= config.loopCount) break

                // Saat dijeda: cek ulang tiap 100 ms. delay() = tidak memblokir thread.
                if (paused) {
                    delay(100)
                    continue
                }

                val success = when (config.actionType) {
                    ActionType.CLICK -> performClick(config.x, config.y)
                    ActionType.SCROLL -> performScrollDown(
                        config.x, config.y, config.scrollDistance, config.scrollDurationMs
                    )
                }

                if (!success) {
                    finishWithError("Gestur ditolak sistem. Periksa koordinat & status layanan.")
                    return
                }

                executedCount++
                AutomationBridge.emit("progress", mapOf("executed" to executedCount))

                delay(config.intervalMs.coerceAtLeast(MIN_INTERVAL_MS))
            }

            // Keluar normal karena loopCount tercapai
            state = AutomationState.IDLE
            AutomationBridge.emit("finished", mapOf("executed" to executedCount))
        } catch (e: CancellationException) {
            throw e   // WAJIB dilempar ulang agar pembatalan coroutine berjalan benar
        } catch (e: Exception) {
            Log.e(TAG, "Loop otomasi error", e)
            finishWithError(e.message ?: "Kesalahan tak diketahui")
        }
    }

    private fun finishWithError(message: String) {
        state = AutomationState.IDLE
        paused = false
        AutomationBridge.emit("error", mapOf("message" to message))
    }

    // ───────────── Gesture Injection ─────────────

    /** Satu ketukan di (x, y). */
    private suspend fun performClick(x: Int, y: Int): Boolean {
        val path = Path().apply { moveTo(x.toFloat(), y.toFloat()) }
        val stroke = GestureDescription.StrokeDescription(path, 0L, CLICK_DURATION_MS)
        return dispatchSuspend(GestureDescription.Builder().addStroke(stroke).build())
    }

    /**
     * Scroll ke bawah = jari bergerak KE ATAS: dari yStart ke yEnd (yEnd < yStart).
     * Durasi menentukan kehalusan: terlalu cepat dianggap fling.
     */
    private suspend fun performScrollDown(
        x: Int,
        yStart: Int,
        distance: Int,
        durationMs: Long
    ): Boolean {
        val yEnd = (yStart - distance).coerceAtLeast(0)
        val path = Path().apply {
            moveTo(x.toFloat(), yStart.toFloat())
            lineTo(x.toFloat(), yEnd.toFloat())
        }
        val stroke = GestureDescription.StrokeDescription(path, 0L, durationMs)
        return dispatchSuspend(GestureDescription.Builder().addStroke(stroke).build())
    }

    /**
     * Membungkus dispatchGesture (berbasis callback) menjadi fungsi suspend.
     * - dispatchGesture dipanggil di Main thread (handler = null → callback juga di Main).
     * - Coroutine pemanggil (di Default) "menunggu" tanpa memblokir thread apa pun.
     * Mengembalikan true jika gestur selesai, false jika dibatalkan/ditolak.
     */
    private suspend fun dispatchSuspend(gesture: GestureDescription): Boolean =
        withContext(Dispatchers.Main) {
            suspendCancellableCoroutine { cont ->
                val callback = object : GestureResultCallback() {
                    override fun onCompleted(gestureDescription: GestureDescription?) {
                        if (cont.isActive) cont.resume(true)
                    }

                    override fun onCancelled(gestureDescription: GestureDescription?) {
                        if (cont.isActive) cont.resume(false)
                    }
                }
                val accepted = dispatchGesture(gesture, callback, null)
                if (!accepted && cont.isActive) cont.resume(false)
            }
        }

    // ───────────── Validasi ─────────────

    private fun validate(config: AutomationConfig) {
        val dm = resources.displayMetrics
        require(config.x in 0 until dm.widthPixels) {
            "Koordinat X harus 0..${dm.widthPixels - 1} px"
        }
        require(config.y in 0 until dm.heightPixels) {
            "Koordinat Y harus 0..${dm.heightPixels - 1} px"
        }
        require(config.intervalMs >= MIN_INTERVAL_MS) {
            "Interval minimal $MIN_INTERVAL_MS ms"
        }
        require(config.loopCount >= 0) { "Jumlah loop tidak boleh negatif" }

        if (config.actionType == ActionType.SCROLL) {
            require(config.scrollDistance >= 50) { "Jarak scroll minimal 50 px" }
            require(config.y - config.scrollDistance >= 0 || config.y >= 50) {
                "Titik awal Y terlalu dekat tepi atas"
            }
            require(config.scrollDurationMs in 100..GestureDescription.getMaxGestureDuration()) {
                "Durasi scroll di luar rentang yang diizinkan"
            }
        }
    }
}

