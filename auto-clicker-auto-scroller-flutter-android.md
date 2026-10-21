# Membangun Auto Clicker & Auto Scroller Minimalis: Full Stack Flutter & Android Native

> **Level:** Pemula–Menengah  |  **Platform:** Android 7.0+ (API 24+)  |  **Bahasa:** Dart (Flutter) & Kotlin
> **Hasil akhir:** Aplikasi 1 halaman untuk mengatur koordinat, interval, dan mode (klik / scroll ke bawah). Setelah tombol **Mulai Otomasi** ditekan, gestur dijalankan secara native oleh `AccessibilityService`, bahkan ketika aplikasi diminimalkan.

---

## Daftar Isi

0. [Gambaran Proyek & Persiapan](#0-gambaran-proyek--persiapan)
1. [Modul 1: Konsep Native Bridge & Android Accessibility Service](#modul-1-konsep-native-bridge--android-accessibility-service)
2. [Modul 2: Core Native Service (Gesture Injection: Klik & Scroll)](#modul-2-core-native-service-gesture-injection-klik--scroll)
3. [Modul 3: Controller & State Management di Flutter](#modul-3-controller--state-management-di-flutter)
4. [Modul 4: UI Konfigurasi Minimalis & Headless Execution](#modul-4-ui-konfigurasi-minimalis--headless-execution)
5. [Pengujian, Troubleshooting & Langkah Lanjutan](#5-pengujian-troubleshooting--langkah-lanjutan)

---

## 0. Gambaran Proyek & Persiapan

### 0.1 Pembagian Tugas

| Lapisan | Teknologi | Tanggung jawab |
|---|---|---|
| **UI & Konfigurasi** | Flutter (Dart) | Form koordinat, interval, mode; tombol Mulai/Jeda/Hentikan; menampilkan status |
| **Jembatan** | `MethodChannel` | Mengirim perintah Dart → Kotlin dan status Kotlin → Dart |
| **Mesin Otomasi** | Kotlin `AccessibilityService` | Loop otomasi, membuat dan menyuntikkan gestur klik/scroll ke layar |

Prinsip penting: **Flutter hanya remote control. Seluruh "pekerjaan berat" ada di service native.** Itulah sebabnya otomasi tetap jalan saat UI Flutter tidak terlihat.

### 0.2 Arsitektur Menyeluruh

```
┌─────────────────────────── PROSES APLIKASI ────────────────────────────┐
│                                                                        │
│  ┌──────────────┐  MethodChannel   ┌──────────────┐   state/event      │
│  │  Flutter UI  │ ───────────────► │ MainActivity │ ◄───────────────┐  │
│  │ (Dart, UI    │  startAutomation │ (Kotlin,     │                 │  │
│  │  isolate)    │ ◄─────────────── │  Main thread)│                 │  │
│  └──────────────┘  onStatusChanged └──────┬───────┘                 │  │
│                                           │ memanggil               │  │
│                                           ▼                         │  │
│                              ┌─────────────────────────┐            │  │
│                              │  AutoClickerService     │ ───────────┘  │
│                              │  (AccessibilityService) │  AutomationBridge
│                              │  Loop di Dispatchers.   │               │
│                              │  Default (coroutine)    │               │
│                              └───────────┬─────────────┘               │
└──────────────────────────────────────────┼─────────────────────────────┘
                                           │ dispatchGesture()
                                           ▼
                          Layar / aplikasi lain (klik & swipe)
```

### 0.3 Membuat Proyek

```bash
flutter create --org com.example --platforms android auto_clicker
cd auto_clicker
```

Dengan perintah di atas, `applicationId` dan package Kotlin menjadi **`com.example.auto_clicker`**. Seluruh contoh di dokumen ini memakai nama tersebut. Jika Anda memakai nama lain, sesuaikan `package`, nama channel, dan path folder.

Struktur file yang akan kita buat/ubah:

```
auto_clicker/
├── lib/
│   ├── main.dart
│   ├── automation_config.dart
│   ├── automation_channel.dart
│   ├── automation_controller.dart
│   └── automation_page.dart
└── android/app/
    ├── build.gradle.kts                      (tambah dependency coroutine, minSdk)
    └── src/main/
        ├── AndroidManifest.xml               (daftarkan service)
        ├── res/xml/accessibility_service_config.xml   (BARU)
        ├── res/values/strings.xml            (BARU/ubah)
        └── kotlin/com/example/auto_clicker/
            ├── MainActivity.kt
            ├── AutoClickerService.kt         (BARU)
            └── AutomationBridge.kt           (BARU)
```

> ⚠️ **Catatan etika & kebijakan.** `AccessibilityService` adalah API yang sangat kuat. Gunakan hanya pada perangkat dan aplikasi milik Anda sendiri, atau untuk keperluan pengujian dan aksesibilitas yang sah. Jangan dipakai untuk curang di game online, penipuan, atau melanggar ketentuan layanan aplikasi lain. Jika ingin dipublikasikan di Google Play, baca kebijakan *AccessibilityService API* terlebih dahulu.

---

## Modul 1: Konsep Native Bridge & Android Accessibility Service

### 1.1 Mengapa Pure Flutter Tidak Bisa Mengklik Aplikasi Lain?

Android menjalankan setiap aplikasi di dalam **sandbox**: proses terpisah, user ID terpisah, dan jendela (*window*) terpisah. Akibatnya:

1. **Flutter hanya menggambar di jendelanya sendiri.** Widget `GestureDetector`, `Listener`, dan sebagainya hanya *menerima* sentuhan yang sampai ke jendela aplikasi Anda. Tidak ada API Dart untuk *mengirim* sentuhan ke jendela lain.
2. **Menyuntikkan sentuhan lintas aplikasi dilindungi izin sistem.** Izin `INJECT_EVENTS` hanya diberikan kepada aplikasi yang ditandatangani dengan kunci sistem (bukan aplikasi biasa).
3. **Overlay (`SYSTEM_ALERT_WINDOW`) tidak menyelesaikan masalah.** Overlay dapat *menampilkan* sesuatu di atas aplikasi lain, tetapi tidak bisa *membuat* sentuhan untuk aplikasi di bawahnya.
4. **Root atau ADB** (`adb shell input tap`) memang bisa, tetapi tidak bisa diharapkan dari pengguna umum.

Jalan resmi yang disediakan Android adalah **`AccessibilityService`**. Layanan ini dirancang untuk membantu pengguna difabel, dan salah satu kemampuannya adalah `dispatchGesture()`: menyuntikkan gestur (tap, swipe, dll.) ke layar secara sah, **dengan syarat pengguna mengaktifkannya sendiri** di pengaturan sistem.

Konsekuensinya, kode ini **harus ditulis dalam Kotlin/Java** (komponen native). Flutter tidak punya akses langsung ke kelas `AccessibilityService`, sehingga kita memakai **Platform Channel** sebagai jembatan.

### 1.2 Arsitektur Komunikasi `MethodChannel`

`MethodChannel` adalah jalur pesan dua arah berbasis nama string. Kedua sisi harus memakai **nama channel yang identik**.

```
Dart                                   Kotlin
────                                   ──────
invokeMethod('startAutomation', map)  ──►  setMethodCallHandler { call, result -> ... }
                                      ◄──  result.success(...) / result.error(code, msg, details)
setMethodCallHandler(...)             ◄──  channel.invokeMethod('onStatusChanged', map)
```

Aturan emas:

| Aturan | Penjelasan |
|---|---|
| Hanya tipe standar | `null`, `bool`, `int`, `double`, `String`, `List`, `Map`, `Uint8List`. **Objek kustom tidak bisa dikirim**, ubah ke `Map` dulu |
| Handler Kotlin jalan di **Main thread** | Jangan menaruh kerja berat/blocking di dalamnya |
| `invokeMethod` dari Kotlin → Dart harus di **Main thread** | Jika dari thread lain, bungkus dengan `runOnUiThread { ... }` |
| Selalu balas `result` tepat satu kali | `success`, `error`, atau `notImplemented` |
| Error native → `PlatformException` di Dart | Selalu tangkap dengan `try/on PlatformException` |

Daftar method yang akan kita buat:

| Arah | Method | Fungsi |
|---|---|---|
| Dart → Kotlin | `isServiceEnabled` | Apakah layanan aksesibilitas sudah aktif? |
| Dart → Kotlin | `openAccessibilitySettings` | Buka layar pengaturan aksesibilitas |
| Dart → Kotlin | `startAutomation` | Mulai otomasi dengan konfigurasi (Map) |
| Dart → Kotlin | `pauseAutomation` / `resumeAutomation` | Jeda / lanjutkan |
| Dart → Kotlin | `stopAutomation` | Hentikan total |
| Dart → Kotlin | `getStatus` | Ambil status terkini (untuk sinkronisasi UI) |
| Kotlin → Dart | `onStatusChanged` | Kabar status: `running`, `paused`, `stopped`, `finished`, `progress`, `error`, dst. |

### 1.3 Setup Dependency & minSdk

Buka `android/app/build.gradle.kts` lalu pastikan:

```kotlin
android {
    // ... namespace, compileSdk, dll. biarkan bawaan
    defaultConfig {
        applicationId = "com.example.auto_clicker"
        minSdk = 24            // dispatchGesture() butuh API 24 (Android 7.0)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }
}

dependencies {
    // Coroutine untuk loop otomasi di background thread
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.1")
}
```

> Jika proyek Anda masih memakai `build.gradle` (Groovy), padanannya: `minSdkVersion 24` dan `implementation 'org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.1'`.

### 1.4 Konfigurasi XML Accessibility

Buat file `android/app/src/main/res/xml/accessibility_service_config.xml` (buat folder `xml` jika belum ada):

```xml
<?xml version="1.0" encoding="utf-8"?>
<accessibility-service
    xmlns:android="http://schemas.android.com/apk/res/android"
    android:description="@string/accessibility_service_description"
    android:accessibilityEventTypes="typeWindowStateChanged"
    android:accessibilityFeedbackType="feedbackGeneric"
    android:accessibilityFlags="flagDefault"
    android:canPerformGestures="true"
    android:canRetrieveWindowContent="false"
    android:notificationTimeout="100" />
```

Arti atribut penting:

| Atribut | Fungsi |
|---|---|
| `canPerformGestures="true"` | **Wajib.** Tanpa ini, `dispatchGesture()` selalu gagal |
| `canRetrieveWindowContent="false"` | Kita tidak perlu membaca isi layar → lebih aman & privasi lebih baik |
| `accessibilityEventTypes` | Event yang ingin diterima. Kita tidak memproses event, jadi pilih satu yang ringan |
| `description` | Teks penjelasan yang tampil di pengaturan sistem untuk pengguna |

Tambahkan string di `android/app/src/main/res/values/strings.xml`:

```xml
<?xml version="1.0" encoding="utf-8"?>
<resources>
    <string name="accessibility_service_label">Auto Clicker Service</string>
    <string name="accessibility_service_description">Digunakan untuk mensimulasikan ketukan dan geser layar secara otomatis sesuai pengaturan Anda. Tidak membaca isi layar.</string>
</resources>
```

### 1.5 Mendaftarkan Service di Manifest

Di `android/app/src/main/AndroidManifest.xml`, tambahkan blok `<service>` **di dalam `<application>`** (sejajar dengan `<activity>`):

```xml
<service
    android:name=".AutoClickerService"
    android:exported="true"
    android:label="@string/accessibility_service_label"
    android:permission="android.permission.BIND_ACCESSIBILITY_SERVICE">
    <intent-filter>
        <action android:name="android.accessibilityservice.AccessibilityService" />
    </intent-filter>
    <meta-data
        android:name="android.accessibilityservice"
        android:resource="@xml/accessibility_service_config" />
</service>
```

Penjelasan:

- `android:permission="...BIND_ACCESSIBILITY_SERVICE"` memastikan **hanya sistem Android** yang boleh terhubung ke service ini. Karena itulah `exported="true"` tetap aman. Sistem berada di proses lain, jadi harus "terlihat".
- `<meta-data>` menghubungkan service dengan file XML konfigurasi di 1.4.
- Tidak ada izin `<uses-permission>` lain yang diperlukan untuk gestur.

### 1.6 Penanganan Izin Pengguna

Izin aksesibilitas **tidak bisa diminta lewat dialog runtime** seperti kamera. Aplikasi hanya bisa:

1. Memeriksa apakah service sudah aktif.
2. Mengarahkan pengguna ke layar pengaturan: `Settings.ACTION_ACCESSIBILITY_SETTINGS`.
3. Pengguna mencari "Auto Clicker Service" → mengaktifkan → menyetujui peringatan sistem.

Cara paling sederhana dan andal untuk mengecek aktif/tidaknya: service menyimpan referensi dirinya di `companion object` ketika `onServiceConnected()` dipanggil dan menghapusnya saat dimatikan (kita implementasikan di Modul 2). Jika `instance != null`, berarti service aktif.

> 📌 **Android 13+ dan "Restricted Settings".** Jika APK dipasang manual (*sideload*, bukan dari Play Store), tombol aktifkan bisa tampak abu-abu. Buka **Info Aplikasi → ⋮ (menu) → Izinkan pengaturan terbatas** (*Allow restricted settings*), lalu ulangi mengaktifkan service.

### 1.7 Menulis Sisi Native Channel (Kerangka)

Pertama, buat jembatan event dari service ke Activity. File `AutomationBridge.kt`:

```kotlin
package com.example.auto_clicker

/**
 * Perantara sederhana antara AutoClickerService (yang punya lifecycle sendiri)
 * dan MainActivity (yang memegang MethodChannel).
 * Service memanggil emit(); Activity mendaftarkan listener saat engine Flutter siap.
 */
object AutomationBridge {
    @Volatile
    var listener: ((status: String, data: Map<String, Any?>) -> Unit)? = null

    fun emit(status: String, data: Map<String, Any?> = emptyMap()) {
        listener?.invoke(status, data)
    }
}
```

Kerangka `MainActivity.kt` (bagian pemanggilan service dilengkapi di Modul 2):

```kotlin
package com.example.auto_clicker

import android.content.Intent
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    companion object {
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

                else -> result.notImplemented()
            }
        }

        // Teruskan event dari service ke Dart (selalu di Main thread!)
        AutomationBridge.listener = { status, data ->
            runOnUiThread {
                channel?.invokeMethod(
                    "onStatusChanged",
                    mapOf("status" to status, "data" to data)
                )
            }
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        AutomationBridge.listener = null
        channel?.setMethodCallHandler(null)
        channel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
```

Perhatikan dua hal: `val ch` lokal dipakai untuk memasang handler (alasannya ada di *Debug Challenge* di bawah), dan `runOnUiThread` memastikan `invokeMethod` dipanggil dari Main thread meskipun event berasal dari thread coroutine.

### 1.8 Evaluasi Modul 1

#### 🛠️ A. Tugas Praktik (Ganti Baris Kode)

Cuplikan berikut sengaja belum benar. Tombol "Buka Pengaturan" di UI membuka layar yang salah.

```kotlin
"openAccessibilitySettings" -> {
    startActivity(Intent(Settings.ACTION_SETTINGS))   // <-- perhatikan baris ini
    result.success(null)
}
```

**Instruksi:** Ganti baris `startActivity(Intent(Settings.ACTION_SETTINGS))` menjadi `startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))` agar pengguna langsung diarahkan ke daftar layanan aksesibilitas, bukan ke halaman pengaturan umum yang membingungkan.

<details>
<summary>Lihat Solusi & Penjelasan</summary>

**Kode benar:**

```kotlin
"openAccessibilitySettings" -> {
    startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
    result.success(null)
}
```

**Penjelasan teknis:**

- `Settings.ACTION_SETTINGS` membuka halaman utama pengaturan, sehingga pengguna harus mencari sendiri menu Aksesibilitas. Banyak yang menyerah di tahap ini.
- `Settings.ACTION_ACCESSIBILITY_SETTINGS` adalah *intent action* khusus yang membuka langsung layar aksesibilitas, tempat layanan kita ("Auto Clicker Service") terdaftar.
- Tidak perlu `FLAG_ACTIVITY_NEW_TASK` karena `startActivity` dipanggil dari `Activity`. Flag itu baru wajib jika dipanggil dari `Context` non-Activity (misalnya dari Service).
- Jangan lupa `result.success(null)` agar `Future` di sisi Dart selesai. Tanpa itu `await openAccessibilitySettings()` akan menggantung selamanya.

</details>

#### 🐞 B. Tantangan "Fix the Syntax" (Debug Challenge)

Kode berikut gagal dikompilasi:

```kotlin
class MainActivity : FlutterActivity() {

    private var channel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.example.auto_clicker/automation")
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "isServiceEnabled" -> result.success(AutoClickerService.instance != null)
                else -> result.notImplemented()
            }
        }
    }
}
```

Pesan error (simulasi Gradle/kotlinc):

```text
> Task :app:compileDebugKotlin FAILED
e: file:///home/dev/auto_clicker/android/app/src/main/kotlin/com/example/auto_clicker/MainActivity.kt:14:9 Only safe (?.) or non-null asserted (!!.) calls are allowed on a nullable receiver of type 'MethodChannel?'.

FAILURE: Build failed with an exception.
* What went wrong:
Execution failed for task ':app:compileDebugKotlin'.
> Compilation error. See log for more details
```

**Tugas:** Perbaiki kode dan jelaskan penyebab error.

<details>
<summary>Perbaikan Sintaks & Pembahasan</summary>

**Perbaikan (disarankan, pakai variabel lokal non-null):**

```kotlin
override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)

    val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.example.auto_clicker/automation")
    channel = ch   // simpan ke properti untuk dipakai/dibersihkan nanti

    ch.setMethodCallHandler { call, result ->
        when (call.method) {
            "isServiceEnabled" -> result.success(AutoClickerService.instance != null)
            else -> result.notImplemented()
        }
    }
}
```

**Penyebab error:**

`channel` dideklarasikan sebagai `MethodChannel?` (nullable) dan berupa `var` properti kelas. Walaupun baris sebelumnya baru saja mengisinya dengan objek non-null, Kotlin **tidak mengizinkan smart cast** pada properti `var` karena properti itu bisa diubah thread lain di antara dua baris. Jadi `channel.setMethodCallHandler` dianggap memanggil metode pada objek yang mungkin `null`.

Alternatif yang valid namun kurang elegan: `channel?.setMethodCallHandler { ... }` atau `channel!!.setMethodCallHandler { ... }`. Pola variabel lokal `val` lebih aman karena nilai `val` lokal tidak bisa berubah, sehingga tidak ada risiko `NullPointerException`.

</details>

#### ✅ C. Checkpoint Pemahaman

1. Mengapa `exported="true"` pada service aksesibilitas masih aman?
2. Apa yang terjadi jika `canPerformGestures` tidak diset `true`?
3. Dari thread mana `invokeMethod` Kotlin → Dart harus dipanggil?

<details>
<summary>Lihat Jawaban</summary>

1. Karena dilindungi `android:permission="android.permission.BIND_ACCESSIBILITY_SERVICE"`; hanya sistem yang boleh *bind*, aplikasi lain tidak bisa.
2. `dispatchGesture()` gagal (mengembalikan `false`/tidak berefek) karena service tidak diberi kapabilitas gestur.
3. Main thread (gunakan `runOnUiThread { ... }` bila event datang dari thread lain).

</details>

---

## Modul 2: Core Native Service (Gesture Injection: Klik & Scroll)

### 2.1 Konsep Dasar `GestureDescription`

Gestur di Android dimodelkan dengan tiga objek:

```
GestureDescription          ← satu "paket" gestur
  └─ StrokeDescription      ← satu goresan jari (path, startTime, duration)
       └─ Path              ← jalur yang dilalui jari (moveTo, lineTo)
```

| Gestur | Bentuk `Path` | Durasi tipikal |
|---|---|---|
| **Klik (tap)** | `moveTo(x, y)` saja (tanpa `lineTo`) | 50 ms |
| **Scroll ke bawah** | `moveTo(x, yStart)` lalu `lineTo(x, yEnd)` dengan **`yEnd < yStart`** | 300–800 ms |

> 🔑 **Arah scroll itu kontra-intuitif.** Untuk menggulir konten **ke bawah** (melihat isi di bawahnya), jari harus **bergerak ke atas**. Dalam koordinat layar, `y = 0` ada di atas, jadi jari bergerak dari `y` besar ke `y` kecil: **`yEnd < yStart`**.

Aturan penting:

- Tipe parameter ketat: `Path.moveTo(Float, Float)`, `StrokeDescription(Path, Long startTime, Long duration)`.
- `duration` harus > 0 dan tidak melebihi `GestureDescription.getMaxGestureDuration()`.
- Koordinat memakai **piksel fisik** layar (bukan dp). Kita bahas dampaknya di UI (Modul 4).
- **Durasi swipe menentukan kehalusan.** Jika terlalu pendek (misal < 150 ms), sistem menganggapnya *fling* (lemparan) sehingga konten meluncur jauh dan tidak terkontrol. Durasi 300–800 ms menghasilkan drag yang halus dan terprediksi.

### 2.2 Manajemen Thread & Coroutine (Bagian Terpenting!)

Ada **tiga "pemain thread"** dalam proyek ini. Pahami pembagiannya agar tidak ada UI freeze maupun ANR:

| Thread | Siapa yang berjalan di sini | Aturan |
|---|---|---|
| **Dart UI isolate** (Flutter) | Build widget, setState, event tombol, pemrosesan hasil `invokeMethod` | `await` pada `invokeMethod` **tidak memblokir** UI. Dart menunggu secara asinkron |
| **Android Main thread** (Platform thread) | Handler `MethodChannel`, callback lifecycle service (`onServiceConnected`, dll.), pemanggilan `dispatchGesture` | **Jangan pernah** `Thread.sleep()`, loop `while(true)` tanpa suspend, atau kerja berat di sini. Blokir > ±5 detik saat ada input → **ANR** |
| **`Dispatchers.Default`** (background pool) | **Loop otomasi** milik kita | Boleh menunggu lama, tetapi gunakan `delay()` (suspend), bukan `Thread.sleep()` |

Strategi desain:

```
Main thread:     [terima startAutomation] → launch coroutine → SELESAI (cepat, <1 ms)
                                              │
Default thread:                               └─► while(aktif) {
                                                      buat gestur
                                                      ──► pindah sebentar ke Main: dispatchGesture()
                                                      ◄── tunggu callback onCompleted/onCancelled (suspend)
                                                      delay(interval)   ← suspend, TIDAK memblokir thread
                                                  }
```

Poin kunci:

1. **`delay()` adalah fungsi suspend.** Coroutine "tidur" tanpa menahan thread. Ini sebabnya loop tidak membuat ANR.
2. `dispatchGesture()` dipanggil di Main thread lewat `withContext(Dispatchers.Main)` karena callback default-nya juga dikirim ke Main thread (kita pasang `handler = null`). Pemanggilannya sendiri sangat cepat.
3. Hasil gestur (`onCompleted` / `onCancelled`) dijembatani menjadi fungsi `suspend` dengan `suspendCancellableCoroutine`. Dengan begitu loop **menunggu gestur selesai dulu** sebelum menghitung interval. Tidak ada gestur yang bertumpuk.
4. Stop = `job.cancel()`. Coroutine yang sedang `delay()` berhenti seketika.
5. Hasil ke Dart dikirim lewat `AutomationBridge.emit()` dari thread background; `MainActivity` yang memindahkannya ke Main thread (sudah kita siapkan di Modul 1).

### 2.3 Model Konfigurasi Native

Tambahkan di file `AutoClickerService.kt` (di atas kelas service):

```kotlin
package com.example.auto_clicker

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
```

### 2.4 Kelas `AutoClickerService` Lengkap

```kotlin
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
```

> 📝 `resources.displayMetrics` memberi estimasi ukuran layar dalam piksel. Pada beberapa perangkat angkanya tidak menyertakan area *navigation bar*. Anggap ini validasi kasar. Jika koordinat tetap di luar jangkauan, `dispatchGesture` akan mengembalikan `false` dan kita menampilkan error.

### 2.5 Menghubungkan Service ke `MethodChannel`

Lengkapi `setMethodCallHandler` pada `MainActivity` (ganti blok `when` dari Modul 1) dan tambahkan fungsi pembantu `parseConfig`:

```kotlin
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
}
```

Fungsi pembantu di dalam kelas `MainActivity`:

```kotlin
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
        call.argument<Int>(key) ?: throw IllegalArgumentException("Argumen '$key' wajib diisi")

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
```

Tambahkan import `io.flutter.plugin.common.MethodCall` di bagian atas file.

### 2.6 Alur Eksekusi Satu Siklus (Ringkas)

```
[Dart] tekan "Mulai"
   └► invokeMethod('startAutomation', map)
        └► [Main thread] parseConfig → svc.startAutomation() → scope.launch → result.success()   (< 1 ms)
             └► [Default thread] runLoop:
                   ├─ buat Path/Stroke/Gesture
                   ├─ withContext(Main): dispatchGesture()  ──►  Android menggerakkan "jari virtual"
                   ├─ menunggu callback onCompleted (suspend)
                   ├─ emit("progress")  ──► MainActivity.runOnUiThread ──► Dart onStatusChanged
                   └─ delay(interval)   (suspend, tidak memblokir)
```

### 2.7 Evaluasi Modul 2

#### 🛠️ A. Tugas Praktik (Ganti Baris Kode)

Seorang pengembang melaporkan dua masalah: (1) mode scroll malah menggulir konten **ke atas**, dan (2) aplikasi sesekali membeku. Cuplikan kodenya:

```kotlin
private suspend fun performScrollDown(x: Int, yStart: Int, distance: Int, durationMs: Long): Boolean {
    val yEnd = yStart + distance                       // <-- (1)
    val path = Path().apply {
        moveTo(x.toFloat(), yStart.toFloat())
        lineTo(x.toFloat(), yEnd.toFloat())
    }
    val stroke = GestureDescription.StrokeDescription(path, 0L, durationMs)
    return dispatchSuspend(GestureDescription.Builder().addStroke(stroke).build())
}

fun startAutomation(config: AutomationConfig) {
    // ...
    loopJob = scope.launch(Dispatchers.Main) { runLoop(config) }   // <-- (2)
}
```

**Instruksi 1:** Ganti baris `val yEnd = yStart + distance` menjadi `val yEnd = (yStart - distance).coerceAtLeast(0)` agar jari bergerak ke atas (menggulir konten ke bawah) dan koordinat tidak negatif.

**Instruksi 2:** Ganti baris `loopJob = scope.launch(Dispatchers.Main) { runLoop(config) }` menjadi `loopJob = scope.launch { runLoop(config) }` agar loop berjalan di `Dispatchers.Default` (sesuai `scope`) dan tidak membebani Main thread.

<details>
<summary>Lihat Solusi & Penjelasan</summary>

**Kode benar:**

```kotlin
val yEnd = (yStart - distance).coerceAtLeast(0)
```

```kotlin
loopJob = scope.launch { runLoop(config) }
```

**Penjelasan (1), arah scroll:**
Pada sistem koordinat Android, `y = 0` berada di sisi **atas** layar dan nilai bertambah ke bawah. Untuk menggulir *konten* ke bawah, jari harus menyeret dari bawah ke atas, jadi `yEnd < yStart`. Kode lama (`yStart + distance`) menggerakkan jari ke bawah sehingga konten bergeser ke atas, yaitu kebalikan dari yang diinginkan. `coerceAtLeast(0)` mencegah koordinat negatif, yang akan membuat `Path` di luar layar dan gestur gagal.

**Penjelasan (2), thread:**
`scope.launch(Dispatchers.Main)` memaksa seluruh `runLoop` berjalan di Main thread. Walaupun `delay()` tidak memblokir, setiap iterasi (membangun path, emit event, dll.) tetap berebut waktu dengan rendering UI, handler `MethodChannel`, dan input sistem. Pada interval kecil, hal ini memunculkan jank dan berisiko ANR. Dengan `scope.launch { ... }` (memakai `Dispatchers.Default` dari definisi scope), Main thread hanya dipakai sesaat ketika memanggil `dispatchGesture` lewat `withContext(Dispatchers.Main)`.

</details>

#### 🐞 B. Tantangan "Fix the Syntax" (Debug Challenge)

```kotlin
private fun buildScrollGesture(x: Int, yStart: Int, yEnd: Int, durationMs: Int): GestureDescription {
    val path = Path()
    path.moveTo(x, yStart)
    path.lineTo(x, yEnd)
    val stroke = GestureDescription.StrokeDescription(path, 0, durationMs)
    return GestureDescription.Builder().addStroke(stroke).build()
}
```

Pesan error (simulasi Gradle/kotlinc):

```text
> Task :app:compileDebugKotlin FAILED
e: file:///home/dev/auto_clicker/android/app/src/main/kotlin/com/example/auto_clicker/AutoClickerService.kt:92:24 Argument type mismatch: actual type is 'Int', but 'Float' was expected.
e: file:///home/dev/auto_clicker/android/app/src/main/kotlin/com/example/auto_clicker/AutoClickerService.kt:92:27 Argument type mismatch: actual type is 'Int', but 'Float' was expected.
e: file:///home/dev/auto_clicker/android/app/src/main/kotlin/com/example/auto_clicker/AutoClickerService.kt:93:24 Argument type mismatch: actual type is 'Int', but 'Float' was expected.
e: file:///home/dev/auto_clicker/android/app/src/main/kotlin/com/example/auto_clicker/AutoClickerService.kt:93:27 Argument type mismatch: actual type is 'Int', but 'Float' was expected.
e: file:///home/dev/auto_clicker/android/app/src/main/kotlin/com/example/auto_clicker/AutoClickerService.kt:94:70 Argument type mismatch: actual type is 'Int', but 'Long' was expected.

FAILURE: Build failed with an exception.
```

**Tugas:** Perbaiki kode dan jelaskan mengapa error muncul.

<details>
<summary>Perbaikan Sintaks & Pembahasan</summary>

**Kode perbaikan:**

```kotlin
private fun buildScrollGesture(x: Int, yStart: Int, yEnd: Int, durationMs: Long): GestureDescription {
    val path = Path().apply {
        moveTo(x.toFloat(), yStart.toFloat())
        lineTo(x.toFloat(), yEnd.toFloat())
    }
    val stroke = GestureDescription.StrokeDescription(path, 0L, durationMs)
    return GestureDescription.Builder().addStroke(stroke).build()
}
```

**Penyebab error:**

Kotlin **tidak melakukan konversi numerik implisit**, berbeda dengan Java yang melakukan *widening* otomatis. Sehingga:

- `Path.moveTo()` dan `Path.lineTo()` menerima `Float`. Memasukkan `Int` (`x`, `yStart`, `yEnd`) harus dikonversi eksplisit lewat `.toFloat()`.
- `StrokeDescription(path, startTime: Long, duration: Long)` menerima `Long`. Literal `0` boleh karena kompilator menyesuaikan literal konstanta, tetapi variabel `durationMs: Int` tidak boleh. Solusinya, ubah tipe parameter menjadi `Long` (lebih bersih daripada `.toLong()` berulang) atau konversi dengan `durationMs.toLong()`.

Tips: biasakan memakai literal `0L` untuk parameter `Long` agar maksud kode jelas.

</details>

#### ✅ C. Checkpoint Pemahaman

1. Mengapa mode scroll ke bawah memakai `yEnd < yStart`?
2. Apa perbedaan `delay(1000)` dan `Thread.sleep(1000)` pada loop otomasi?
3. Mengapa blok `catch (e: CancellationException)` harus melempar ulang (`throw e`)?

<details>
<summary>Lihat Jawaban</summary>

1. Konten bergulir ke bawah ketika jari menyeret ke atas; `y = 0` berada di atas layar.
2. `delay` menangguhkan coroutine tanpa menahan thread; `Thread.sleep` memblokir thread (di Main thread dapat memicu ANR).
3. Pembatalan coroutine bekerja dengan melempar `CancellationException`. Jika ditelan, coroutine tidak berhenti sebagaimana mestinya dan perintah *stop* tidak efektif.

</details>

---

## Modul 3: Controller & State Management di Flutter

Kita memakai pendekatan paling ringan: **`ChangeNotifier`** bawaan Flutter. Tidak perlu package tambahan, ideal untuk aplikasi minimalis.

### 3.1 Model Konfigurasi (`lib/automation_config.dart`)

```dart
enum ActionType { click, scroll }

enum AutomationStatus { idle, running, paused }

class AutomationConfig {
  const AutomationConfig({
    required this.actionType,
    required this.x,
    required this.y,
    this.scrollDistance = 800,
    this.scrollDurationMs = 400,
    this.intervalMs = 1000,
    this.loopCount = 0, // 0 = tak terbatas
  });

  final ActionType actionType;
  final int x;
  final int y; // klik: titik ketuk | scroll: titik awal swipe
  final int scrollDistance; // px, dipakai mode scroll
  final int scrollDurationMs; // ms
  final int intervalMs; // jeda antar aksi (ms)
  final int loopCount; // 0 = tak terbatas

  /// Mengubah objek menjadi Map: satu-satunya bentuk yang dapat dikirim lewat MethodChannel.
  Map<String, dynamic> toMap() => {
        'actionType': actionType.name, // 'click' | 'scroll'
        'x': x,
        'y': y,
        'scrollDistance': scrollDistance,
        'scrollDurationMs': scrollDurationMs,
        'intervalMs': intervalMs,
        'loopCount': loopCount,
      };

  /// Validasi sisi Dart (cepat, sebelum menyentuh native). Null = valid.
  String? validate() {
    if (x < 0 || y < 0) return 'Koordinat tidak boleh negatif.';
    if (intervalMs < 100) return 'Interval minimal 100 ms.';
    if (loopCount < 0) return 'Jumlah loop tidak boleh negatif.';
    if (actionType == ActionType.scroll) {
      if (scrollDistance < 50) return 'Jarak scroll minimal 50 px.';
      if (scrollDurationMs < 100) return 'Durasi scroll minimal 100 ms.';
    }
    return null;
  }
}
```

### 3.2 Lapisan Channel (`lib/automation_channel.dart`)

Semua urusan `MethodChannel` dikumpulkan di satu kelas. UI tidak boleh tahu nama method string.

```dart
import 'package:flutter/services.dart';

import 'automation_config.dart';

typedef NativeStatusCallback = void Function(
  String status,
  Map<String, dynamic> data,
);

class AutomationChannel {
  AutomationChannel() {
    // Mendengarkan panggilan dari Kotlin → Dart
    _channel.setMethodCallHandler(_onNativeCall);
  }

  // Harus identik dengan CHANNEL_NAME di MainActivity.kt
  static const MethodChannel _channel =
      MethodChannel('com.example.auto_clicker/automation');

  NativeStatusCallback? onStatusChanged;

  Future<dynamic> _onNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'onStatusChanged':
        final raw = call.arguments as Map<Object?, Object?>;
        final status = raw['status'] as String? ?? 'unknown';
        final data = Map<String, dynamic>.from(raw['data'] as Map? ?? const {});
        onStatusChanged?.call(status, data);
        return null;
      default:
        throw MissingPluginException('Method ${call.method} tidak dikenal');
    }
  }

  // ───── Dart → Kotlin ─────

  Future<bool> isServiceEnabled() async {
    try {
      return await _channel.invokeMethod<bool>('isServiceEnabled') ?? false;
    } on PlatformException {
      return false;
    }
  }

  Future<void> openAccessibilitySettings() =>
      _channel.invokeMethod<void>('openAccessibilitySettings');

  Future<Map<String, dynamic>> getStatus() async {
    final raw = await _channel.invokeMapMethod<String, dynamic>('getStatus');
    return raw ?? <String, dynamic>{};
  }

  Future<void> startAutomation(AutomationConfig config) =>
      _channel.invokeMethod<void>('startAutomation', config.toMap());

  Future<void> pauseAutomation() => _channel.invokeMethod<void>('pauseAutomation');

  Future<void> resumeAutomation() => _channel.invokeMethod<void>('resumeAutomation');

  Future<void> stopAutomation() => _channel.invokeMethod<void>('stopAutomation');
}
```

### 3.3 Controller (`lib/automation_controller.dart`)

Controller adalah **satu-satunya sumber kebenaran (single source of truth)** untuk status otomasi di sisi Flutter.

```dart
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';

import 'automation_channel.dart';
import 'automation_config.dart';

class AutomationController extends ChangeNotifier with WidgetsBindingObserver {
  AutomationController(this._channel) {
    WidgetsBinding.instance.addObserver(this);
    _channel.onStatusChanged = _handleNativeStatus;
    refresh();
  }

  final AutomationChannel _channel;

  AutomationStatus _status = AutomationStatus.idle;
  bool _serviceEnabled = false;
  int _executed = 0;
  String? _message;

  AutomationStatus get status => _status;
  bool get serviceEnabled => _serviceEnabled;
  int get executed => _executed;
  String? get message => _message;
  bool get isRunning => _status == AutomationStatus.running;
  bool get isPaused => _status == AutomationStatus.paused;
  bool get isActive => isRunning || isPaused;

  // ───── Sinkronisasi ─────

  /// Menarik status asli dari native. Dipanggil saat awal & ketika app kembali ke foreground.
  Future<void> refresh() async {
    _serviceEnabled = await _channel.isServiceEnabled();
    if (_serviceEnabled) {
      final s = await _channel.getStatus();
      _status = _parseState(s['state'] as String?);
      _executed = (s['executed'] as int?) ?? 0;
    } else {
      _status = AutomationStatus.idle;
    }
    notifyListeners();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Native tetap berjalan di background; kita hanya menyegarkan tampilan saat kembali.
    if (state == AppLifecycleState.resumed) {
      refresh();
    }
  }

  // ───── Perintah ke native ─────

  Future<void> start(AutomationConfig config) async {
    final error = config.validate();
    if (error != null) {
      _message = error;
      notifyListeners();
      return;
    }
    await _guard(() => _channel.startAutomation(config));
  }

  Future<void> pause() => _guard(_channel.pauseAutomation);
  Future<void> resume() => _guard(_channel.resumeAutomation);
  Future<void> stop() => _guard(_channel.stopAutomation);
  Future<void> openSettings() => _channel.openAccessibilitySettings();

  /// Membungkus setiap pemanggilan native agar PlatformException tidak pernah lolos.
  Future<void> _guard(Future<void> Function() action) async {
    try {
      await action();
      _message = null;
    } on PlatformException catch (e) {
      switch (e.code) {
        case 'SERVICE_NOT_ENABLED':
          _serviceEnabled = false;
          _message = 'Layanan aksesibilitas belum aktif. Aktifkan dulu di Pengaturan.';
        case 'INVALID_ARGUMENT':
          _message = e.message ?? 'Konfigurasi tidak valid.';
        default:
          _message = 'Gagal: ${e.message ?? e.code}';
      }
      notifyListeners();
    } on MissingPluginException {
      _message = 'Kode native belum terpasang (coba jalankan ulang aplikasi, bukan hot reload).';
      notifyListeners();
    }
  }

  // ───── Callback dari native (Kotlin → Dart) ─────

  void _handleNativeStatus(String status, Map<String, dynamic> data) {
    switch (status) {
      case 'running':
        _status = AutomationStatus.running;
        _message = null;
      case 'paused':
        _status = AutomationStatus.paused;
      case 'stopped':
        _status = AutomationStatus.idle;
        _message = 'Otomasi dihentikan.';
      case 'finished':
        _status = AutomationStatus.idle;
        _executed = (data['executed'] as int?) ?? _executed;
        _message = 'Selesai: $_executed aksi dijalankan.';
      case 'progress':
        _executed = (data['executed'] as int?) ?? _executed;
      case 'serviceConnected':
        _serviceEnabled = true;
      case 'serviceDisconnected':
        _serviceEnabled = false;
        _status = AutomationStatus.idle;
        _message = 'Layanan aksesibilitas dimatikan.';
      case 'error':
        _status = AutomationStatus.idle;
        _message = (data['message'] as String?) ?? 'Terjadi kesalahan.';
    }
    notifyListeners();
  }

  AutomationStatus _parseState(String? s) => switch (s) {
        'running' => AutomationStatus.running,
        'paused' => AutomationStatus.paused,
        _ => AutomationStatus.idle,
      };

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _channel.onStatusChanged = null;
    super.dispose();
  }
}
```

> 💡 **Mengapa UI tidak ikut "memegang" loop?** Loop berjalan di native. Dart hanya mengirim perintah dan menerima kabar. Jika Dart (atau seluruh Activity) mati, otomasi tetap jalan; saat UI hidup lagi, `refresh()` menarik status terkini lewat `getStatus`.

### 3.4 Skenario Penanganan Callback Status

| Event dari native | Efek di controller | Tindakan UI |
|---|---|---|
| `serviceConnected` | `serviceEnabled = true` | Banner peringatan hilang |
| `serviceDisconnected` | `serviceEnabled = false`, status `idle` | Banner muncul lagi, tombol jadi "Aktifkan Izin" |
| `running` / `paused` | Update status | Tombol berubah Mulai ↔ Hentikan |
| `progress` | `executed++` | Teks "Aksi dijalankan: N" |
| `finished` | status `idle` + pesan | Notifikasi selesai |
| `error` | status `idle` + pesan error | Tampilkan pesan merah |
| `PlatformException(SERVICE_NOT_ENABLED)` | `serviceEnabled = false` | Dialog arahkan ke Pengaturan |

### 3.5 Evaluasi Modul 3

#### 🛠️ A. Tugas Praktik (Ganti Baris Kode)

Saat tombol Mulai ditekan, log Flutter menampilkan error serialisasi.

```dart
Future<void> startAutomation(AutomationConfig config) async {
  await _channel.invokeMethod<void>('startAutomation', config);   // <-- baris bermasalah
}
```

Error runtime:

```text
[ERROR:flutter/runtime/dart_vm_initializer.cc] Unhandled Exception: Invalid argument: Instance of 'AutomationConfig'
#0  StandardMessageCodec.writeValue (package:flutter/src/services/message_codecs.dart:...)
```

**Instruksi:** Ganti baris `await _channel.invokeMethod<void>('startAutomation', config);` menjadi `await _channel.invokeMethod<void>('startAutomation', config.toMap());` agar argumen berupa `Map` bertipe dasar yang bisa di-*encode* oleh `StandardMessageCodec`.

<details>
<summary>Lihat Solusi & Penjelasan</summary>

**Kode benar:**

```dart
Future<void> startAutomation(AutomationConfig config) async {
  await _channel.invokeMethod<void>('startAutomation', config.toMap());
}
```

**Penjelasan teknis:**

`MethodChannel` memakai **`StandardMessageCodec`** yang hanya mengenal tipe: `null`, `bool`, `int`, `double`, `String`, `Uint8List`/`Int32List`/dll., `List`, dan `Map`. Objek kustom seperti `AutomationConfig` tidak punya representasi biner standar, sehingga *encoder* melempar `Invalid argument`.

Dengan `toMap()`, kita mengubah objek menjadi `Map<String, dynamic>` berisi tipe-tipe dasar. Di sisi Kotlin, map ini tiba sebagai `Map<String, Any?>`, dibaca dengan `call.argument<Int>("x")`, dst. Nilai `int` Dart yang muat 32-bit tiba sebagai `Int` di Kotlin (bila lebih besar menjadi `Long`).

</details>

#### 🐞 B. Tantangan "Fix the Syntax" (Debug Challenge)

```dart
Future<void> ensureReady() async {
  final enabled = await _channel.invokeMethod<bool>('isServiceEnabled');
  if (enabled) {
    await _channel.invokeMethod('startAutomation', _config.toMap());
  }
}
```

Pesan error (simulasi `dart analyze`):

```text
Analyzing auto_clicker...

  error • A nullable expression can't be used as a condition • lib/automation_channel.dart:41:7
          Try checking that the value isn't 'null' before using it as a condition.

1 issue found.
```

**Tugas:** Perbaiki kode. Bonus: tambahkan penanganan agar `PlatformException` dari native tidak membuat aplikasi *crash*.

<details>
<summary>Perbaikan Sintaks & Pembahasan</summary>

**Kode perbaikan:**

```dart
Future<void> ensureReady() async {
  try {
    final enabled = await _channel.invokeMethod<bool>('isServiceEnabled') ?? false;
    if (enabled) {
      await _channel.invokeMethod<void>('startAutomation', _config.toMap());
    }
  } on PlatformException catch (e) {
    debugPrint('Native error [${e.code}]: ${e.message}');
  }
}
```

**Penyebab error:**

Dengan *sound null safety*, `invokeMethod<bool>` mengembalikan `Future<bool?>`: native boleh membalas `null`. Variabel `enabled` bertipe `bool?`, sementara `if` hanya menerima `bool` non-null. Solusinya memberi nilai bawaan lewat operator `?? false`.

**Bonus (PlatformException):** Jika Kotlin memanggil `result.error(...)`, Dart melempar `PlatformException`. Tanpa `try/on`, pengecualian itu menjadi *unhandled async error*. Menangkapnya di *boundary* ini (atau lebih baik, di `_guard` pada controller) menjaga aplikasi tetap stabil dan memungkinkan pesan yang ramah ke pengguna. Perlu `import 'package:flutter/services.dart';` agar `PlatformException` dikenali.

</details>

#### ✅ C. Checkpoint Pemahaman

1. Mengapa `AutomationConfig` perlu method `toMap()`?
2. Mengapa controller memanggil `refresh()` saat lifecycle `resumed`?
3. Apa kegunaan `with WidgetsBindingObserver`?

<details>
<summary>Lihat Jawaban</summary>

1. Karena `MethodChannel` hanya bisa mengirim tipe standar; objek kustom harus diubah menjadi `Map`.
2. Otomasi berjalan di native saat UI di background; ketika kembali, UI perlu menarik status & hitungan terbaru.
3. Agar controller menerima callback perubahan lifecycle aplikasi (`didChangeAppLifecycleState`).

</details>

---

## Modul 4: UI Konfigurasi Minimalis & Headless Execution

### 4.1 Prinsip Desain UI

Satu halaman, satu tujuan. Urutan dari atas ke bawah:

1. Banner peringatan (hanya muncul jika izin aksesibilitas belum aktif).
2. Pilihan mode: **Otomatis Klik** / **Otomatis Scroll ke Bawah**.
3. Input koordinat X dan Y (+ info resolusi layar).
4. Khusus scroll: jarak swipe dan slider durasi.
5. Slider interval jeda + jumlah loop.
6. Tombol utama **Mulai Otomasi** / **Hentikan** (+ tombol Jeda/Lanjut saat aktif).

> 📐 **Penting: satuan koordinat adalah piksel fisik.** Contoh: layar 1080×2400 px. Tampilan resolusi layar di UI membantu pengguna menentukan angka yang valid. Fitur "ketuk layar untuk memilih koordinat" (overlay) adalah pengembangan lanjutan (lihat bagian 5).

### 4.2 Entry Point (`lib/main.dart`)

```dart
import 'package:flutter/material.dart';

import 'automation_page.dart';

void main() => runApp(const AutoClickerApp());

class AutoClickerApp extends StatelessWidget {
  const AutoClickerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Auto Clicker',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        useMaterial3: true,
      ),
      home: const AutomationPage(),
    );
  }
}
```

### 4.3 Halaman Utama (`lib/automation_page.dart`)

```dart
import 'package:flutter/material.dart';

import 'automation_channel.dart';
import 'automation_config.dart';
import 'automation_controller.dart';

class AutomationPage extends StatefulWidget {
  const AutomationPage({super.key});

  @override
  State<AutomationPage> createState() => _AutomationPageState();
}

class _AutomationPageState extends State<AutomationPage> {
  late final AutomationController _controller;

  final _xCtrl = TextEditingController(text: '540');
  final _yCtrl = TextEditingController(text: '1200');
  final _distCtrl = TextEditingController(text: '800');
  final _loopCtrl = TextEditingController(text: '0');

  ActionType _type = ActionType.click;
  double _interval = 1000; // ms
  double _scrollDuration = 400; // ms

  @override
  void initState() {
    super.initState();
    _controller = AutomationController(AutomationChannel());
  }

  @override
  void dispose() {
    _controller.dispose();
    _xCtrl.dispose();
    _yCtrl.dispose();
    _distCtrl.dispose();
    _loopCtrl.dispose();
    super.dispose();
  }

  AutomationConfig _buildConfig() => AutomationConfig(
        actionType: _type,
        x: int.tryParse(_xCtrl.text) ?? -1,
        y: int.tryParse(_yCtrl.text) ?? -1,
        scrollDistance: int.tryParse(_distCtrl.text) ?? 0,
        scrollDurationMs: _scrollDuration.round(),
        intervalMs: _interval.round(),
        loopCount: int.tryParse(_loopCtrl.text) ?? 0,
      );

  Future<void> _onMainButtonPressed() async {
    // Sedang aktif → tombol berfungsi sebagai "Hentikan"
    if (_controller.isActive) {
      await _controller.stop();
      return;
    }

    // Belum ada izin → arahkan pengguna ke Pengaturan
    if (!_controller.serviceEnabled) {
      final goToSettings = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Aktifkan Layanan Aksesibilitas'),
          content: const Text(
            'Cari "Auto Clicker Service" di daftar layanan, lalu aktifkan. '
            'Setelah itu kembali ke aplikasi ini.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Batal'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Buka Pengaturan'),
            ),
          ],
        ),
      );
      if (goToSettings == true) {
        await _controller.openSettings();
      }
      return;
    }

    await _controller.start(_buildConfig());
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final screenInfo =
        'Layar ± ${(size.width * dpr).round()} × ${(size.height * dpr).round()} px';

    return Scaffold(
      appBar: AppBar(title: const Text('Auto Clicker & Scroller')),
      body: SafeArea(
        child: ListenableBuilder(
          listenable: _controller,
          builder: (context, _) {
            final active = _controller.isActive;
            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (!_controller.serviceEnabled) const _PermissionBanner(),

                // ── Mode ──
                SegmentedButton<ActionType>(
                  segments: const [
                    ButtonSegment(
                      value: ActionType.click,
                      icon: Icon(Icons.touch_app),
                      label: Text('Otomatis Klik'),
                    ),
                    ButtonSegment(
                      value: ActionType.scroll,
                      icon: Icon(Icons.swipe_vertical),
                      label: Text('Scroll ke Bawah'),
                    ),
                  ],
                  selected: {_type},
                  onSelectionChanged: active
                      ? null
                      : (selection) => setState(() => _type = selection.first),
                ),
                const SizedBox(height: 16),

                // ── Koordinat ──
                Text(screenInfo, style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(child: _numberField(_xCtrl, 'X (px)', active)),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _numberField(
                        _yCtrl,
                        _type == ActionType.scroll ? 'Y awal (px)' : 'Y (px)',
                        active,
                      ),
                    ),
                  ],
                ),

                // ── Khusus scroll ──
                if (_type == ActionType.scroll) ...[
                  const SizedBox(height: 12),
                  _numberField(_distCtrl, 'Jarak scroll (px)', active),
                  const SizedBox(height: 8),
                  Text('Durasi geser: ${_scrollDuration.round()} ms'),
                  Slider(
                    value: _scrollDuration,
                    min: 150,
                    max: 1500,
                    divisions: 27,
                    onChanged: active
                        ? null
                        : (v) => setState(() => _scrollDuration = v),
                  ),
                ],

                // ── Interval & loop ──
                const SizedBox(height: 8),
                Text('Interval jeda: ${_interval.round()} ms'),
                Slider(
                  value: _interval,
                  min: 100,
                  max: 5000,
                  divisions: 49,
                  onChanged:
                      active ? null : (v) => setState(() => _interval = v),
                ),
                _numberField(_loopCtrl, 'Jumlah loop (0 = tanpa batas)', active),
                const SizedBox(height: 24),

                // ── Tombol utama ──
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(56),
                    backgroundColor: active ? Colors.red.shade600 : null,
                  ),
                  onPressed: _onMainButtonPressed,
                  icon: Icon(active ? Icons.stop : Icons.play_arrow),
                  label: Text(
                    active
                        ? 'Hentikan'
                        : (_controller.serviceEnabled
                            ? 'Mulai Otomasi'
                            : 'Aktifkan Izin Dulu'),
                  ),
                ),

                if (active) ...[
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed:
                        _controller.isPaused ? _controller.resume : _controller.pause,
                    icon: Icon(
                      _controller.isPaused ? Icons.play_arrow : Icons.pause,
                    ),
                    label: Text(_controller.isPaused ? 'Lanjutkan' : 'Jeda'),
                  ),
                ],

                // ── Status ──
                const SizedBox(height: 16),
                Text(
                  'Status: ${_controller.status.name}  •  Aksi dijalankan: ${_controller.executed}',
                  textAlign: TextAlign.center,
                ),
                if (_controller.message != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      _controller.message!,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Theme.of(context).colorScheme.error),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _numberField(TextEditingController c, String label, bool disabled) {
    return TextField(
      controller: c,
      enabled: !disabled,
      keyboardType: TextInputType.number,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
      ),
    );
  }
}

class _PermissionBanner extends StatelessWidget {
  const _PermissionBanner();

  @override
  Widget build(BuildContext context) {
    return Card(
      color: Theme.of(context).colorScheme.errorContainer,
      margin: const EdgeInsets.only(bottom: 16),
      child: const Padding(
        padding: EdgeInsets.all(12),
        child: Row(
          children: [
            Icon(Icons.warning_amber_rounded),
            SizedBox(width: 12),
            Expanded(
              child: Text(
                'Layanan aksesibilitas belum aktif. Tekan tombol di bawah untuk mengaktifkannya.',
              ),
            ),
          ],
        ),
      ),
    );
  }
}
```

### 4.4 Memahami "Headless Execution"

Saat pengguna menekan tombol Home dan membuka aplikasi lain, terjadi hal berikut:

| Komponen | Status saat app diminimalkan |
|---|---|
| Widget Flutter / UI | Dijeda oleh sistem (tidak menggambar) |
| `AutomationController` (Dart) | Masih hidup selama proses hidup, tetapi tidak dibutuhkan untuk loop |
| `AutoClickerService` | **Tetap berjalan**: service aksesibilitas dikelola sistem, terpisah dari lifecycle Activity |
| Loop coroutine (`Dispatchers.Default`) | **Tetap berjalan**: terikat `scope` milik service, bukan Activity |
| `AutomationBridge.listener` | Bisa saja `null` jika Activity sudah dihancurkan → event dibuang tanpa error |

Alur saat kembali ke aplikasi:

```
resumed ──► didChangeAppLifecycleState ──► refresh() ──► getStatus() ──► UI menampilkan
                                                                          status & hitungan terkini
```

Karena itu, **jangan pernah menghentikan otomasi saat lifecycle `paused`/`inactive`**. Itu justru membunuh fitur utama aplikasi. Cukup sinkronkan saat `resumed`.

Tips agar stabil di perangkat nyata:

- Beberapa vendor (Xiaomi, Oppo, Vivo, Samsung) agresif mematikan proses di background. Minta pengguna mengecualikan aplikasi dari **optimasi baterai** dan mengaktifkan **Autostart** bila tersedia.
- Service aksesibilitas yang aktif umumnya diprioritaskan sistem, tetapi tetap tidak ada jaminan 100% di semua merek.
- Jika layanan dimatikan pengguna di Pengaturan, native mengirim `serviceDisconnected` dan UI otomatis menampilkan banner izin.

### 4.5 Evaluasi Modul 4

#### 🛠️ A. Tugas Praktik (Ganti Baris Kode)

Pengguna mengeluh: *"Setiap kali saya pindah ke aplikasi lain, otomasi berhenti!"* Penyebabnya ada di observer lifecycle berikut:

```dart
@override
void didChangeAppLifecycleState(AppLifecycleState state) {
  if (state == AppLifecycleState.paused) {
    stop();                                   // <-- baris bermasalah
  }
}
```

**Instruksi:** Ganti baris `if (state == AppLifecycleState.paused) { stop(); }` menjadi `if (state == AppLifecycleState.resumed) { refresh(); }` agar otomasi native tidak dimatikan ketika aplikasi diminimalkan, dan tampilan Flutter hanya disinkronkan dengan status native ketika pengguna kembali.

<details>
<summary>Lihat Solusi & Penjelasan</summary>

**Kode benar:**

```dart
@override
void didChangeAppLifecycleState(AppLifecycleState state) {
  if (state == AppLifecycleState.resumed) {
    refresh();
  }
}
```

**Penjelasan teknis:**

- `AppLifecycleState.paused` dipicu ketika aplikasi masuk background (tombol Home, pindah aplikasi). Jika di sana kita memanggil `stop()`, perintah `stopAutomation` dikirim ke native dan loop dibatalkan. Hal ini bertentangan dengan tujuan aplikasi: otomasi harus tetap berjalan di atas aplikasi lain.
- Loop hidup di `AutoClickerService`, bukan di Dart. UI hanya "remote control", sehingga tidak ada alasan menghentikan loop ketika remote disembunyikan.
- `AppLifecycleState.resumed` adalah saat tepat untuk `refresh()`: selama UI di background, event `onStatusChanged` mungkin terlewat (atau Activity sempat dibuat ulang), sehingga status & counter di layar bisa usang. `refresh()` memanggil `isServiceEnabled` + `getStatus` untuk menyamakan kembali.
- `refresh()` juga mendeteksi pengguna yang baru saja mengaktifkan izin dari layar Pengaturan, sehingga banner peringatan hilang otomatis ketika kembali ke aplikasi.

</details>

#### 🐞 B. Tantangan "Fix the Syntax" (Debug Challenge)

```dart
double _interval = 1000;

Future<void> _onStartPressed() async {
  final enabled = await _controller.checkService();
  if (!enabled) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Izin aksesibilitas belum aktif')),
    );
  }
  _controller.setInterval(_interval);   // signature: void setInterval(int ms)
  await _controller.start(_buildConfig());
}
```

Pesan error (simulasi `dart analyze`):

```text
Analyzing auto_clicker...

   info • Don't use 'BuildContext's across async gaps •
          lib/automation_page.dart:78:29 • use_build_context_synchronously
  error • The argument type 'double' can't be assigned to the parameter type 'int' •
          lib/automation_page.dart:82:29 • argument_type_not_assignable

2 issues found.
```

**Tugas:** Perbaiki kode dan jelaskan kedua masalah itu, termasuk satu perilaku yang bisa salah meskipun kode sudah lolos analisis.

<details>
<summary>Perbaikan Sintaks & Pembahasan</summary>

**Kode perbaikan:**

```dart
Future<void> _onStartPressed() async {
  final enabled = await _controller.checkService();

  // Setelah await, widget mungkin sudah dibuang (mis. pengguna menutup halaman).
  if (!mounted) return;

  if (!enabled) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Izin aksesibilitas belum aktif')),
    );
    return;   // <-- hentikan alur; jangan lanjut memulai otomasi tanpa izin
  }

  _controller.setInterval(_interval.round());   // double → int
  await _controller.start(_buildConfig());
}
```

**Penyebab & pembahasan:**

1. **`use_build_context_synchronously`:** Setelah `await`, kontrol berpindah dan `BuildContext` bisa saja sudah *tidak valid* (widget sudah *unmounted*). Memakai `context` pada kondisi itu dapat memicu error "Looking up a deactivated widget's ancestor is unsafe". Solusinya, cek `if (!mounted) return;` sebelum memakai `context`, atau ambil `ScaffoldMessenger.of(context)` *sebelum* `await`.
2. **`argument_type_not_assignable`:** `Slider` menghasilkan `double`, sedangkan `setInterval` menerima `int`. Dart tidak mengonversi otomatis; gunakan `.round()` (atau `.toInt()`).
3. **Bug logika (tidak ditangkap analyzer):** Pada kode asli, setelah menampilkan Snackbar alur tetap berlanjut ke `start(...)` meski izin belum aktif. Hasilnya, native membalas `PlatformException(SERVICE_NOT_ENABLED)`. Tambahkan `return` setelah menampilkan peringatan agar alurnya berhenti di titik yang tepat.

</details>

#### ✅ C. Checkpoint Pemahaman

1. Mengapa otomasi tetap berjalan ketika aplikasi Flutter diminimalkan?
2. Mengapa kolom input dinonaktifkan (`enabled: !disabled`) saat otomasi aktif?
3. Apa fungsi `ListenableBuilder` pada halaman ini?

<details>
<summary>Lihat Jawaban</summary>

1. Loop dijalankan oleh `AutoClickerService` (komponen native dengan scope coroutine sendiri), bukan oleh Dart/Activity.
2. Konfigurasi sudah dikirim ke native saat mulai; mengubah input di tengah jalan tidak berpengaruh dan membingungkan. Hentikan dulu, ubah, lalu mulai lagi.
3. Membangun ulang UI setiap `AutomationController` memanggil `notifyListeners()` tanpa perlu `setState` manual.

</details>

---

## 5. Pengujian, Troubleshooting & Langkah Lanjutan

### 5.1 Langkah Pengujian Menyeluruh

1. Hubungkan perangkat Android fisik (disarankan; emulator juga bisa) dan jalankan:
   ```bash
   flutter run
   ```
   > Setelah menambah kode native (Kotlin, manifest, XML), gunakan **full restart / run ulang**, bukan hot reload.
2. Buka aplikasi → banner merah muncul → tekan **Aktifkan Izin Dulu** → **Buka Pengaturan**.
3. Pilih **Auto Clicker Service** → aktifkan → setujui peringatan. Kembali ke aplikasi; banner akan hilang.
4. **Uji klik:** buka aplikasi penghitung ketukan (*tap counter*) milik Anda atau halaman uji, lalu atur X/Y ke posisi tombolnya. Tekan **Mulai Otomasi** → tekan Home → buka aplikasi uji → hitungan bertambah sesuai interval.
5. **Uji scroll:** buka halaman dengan daftar panjang (misal pengaturan/daftar kontak), mode **Scroll ke Bawah**, X ≈ tengah layar, Y awal ≈ 75% tinggi layar, jarak ≈ 800 px, durasi ≈ 400 ms.
6. Tekan **Hentikan** dari aplikasi, atau lihat log:
   ```bash
   adb logcat -s AutoClickerService
   ```

### 5.2 Tabel Troubleshooting

| Gejala | Kemungkinan penyebab | Solusi |
|---|---|---|
| `MissingPluginException` | Kode native belum ter-*build* | Hentikan app dan `flutter run` ulang; cek nama channel di Dart & Kotlin identik |
| Layanan tidak muncul di daftar Aksesibilitas | `<service>` salah tempat / meta-data salah | Pastikan di dalam `<application>`, path `@xml/accessibility_service_config` benar |
| Tombol aktifkan abu-abu (Android 13+) | *Restricted settings* untuk APK sideload | Info Aplikasi → ⋮ → *Izinkan pengaturan terbatas* |
| `SERVICE_NOT_ENABLED` terus-menerus | Izin dicabut / proses service dimatikan | Matikan lalu aktifkan ulang layanan di Pengaturan |
| Error "Gestur ditolak sistem" | Koordinat di luar layar / `canPerformGestures` belum `true` | Periksa XML config & rentang X/Y |
| Scroll terlalu "meluncur" | Durasi swipe terlalu pendek (dianggap *fling*) | Naikkan durasi ke 400–800 ms |
| Scroll tidak bergerak sama sekali | `yStart` terlalu dekat tepi / jarak terlalu besar | Pilih Y awal sekitar 70–80% tinggi layar |
| Otomasi mati sendiri di background | Optimasi baterai vendor | Matikan optimasi baterai & aktifkan Autostart |
| ANR / UI lag | Loop berjalan di Main thread, atau ada `Thread.sleep` | Pastikan `scope.launch { }` memakai `Dispatchers.Default` dan hanya `delay()` |

### 5.3 Ide Pengembangan Lanjutan

- **Overlay pemilih koordinat:** tampilkan jendela transparan bertipe `TYPE_ACCESSIBILITY_OVERLAY` (tidak butuh izin tampil-di-atas terpisah bila dibuat dari `AccessibilityService`) untuk mengetuk titik dan menyimpan X/Y secara otomatis.
- **Tombol kontrol mengambang** (play/pause) di atas aplikasi lain, agar pengguna tidak perlu kembali ke aplikasi.
- **Scroll arah lain** (atas/kiri/kanan) dengan menukar `yStart/yEnd` atau memakai sumbu X.
- **Multi-langkah (macro):** daftar aksi berurutan (klik A → tunggu → scroll → klik B).
- **Persistensi pengaturan** dengan `shared_preferences`.
- **Notifikasi status** agar pengguna tahu otomasi sedang aktif.
- **Randomisasi ringan** pada interval/koordinat untuk meniru perilaku manusia dalam skenario pengujian UI.

### 5.4 Ringkasan Konsep Kunci

| Konsep | Ingat sebagai |
|---|---|
| Mengapa native? | Flutter tidak bisa menyuntik sentuhan lintas aplikasi; `AccessibilityService.dispatchGesture` bisa |
| Izin | Tidak ada dialog runtime; pengguna wajib mengaktifkan manual di Pengaturan Aksesibilitas |
| Bridge | `MethodChannel`: hanya tipe standar, handler di Main thread, balas `result` sekali |
| Klik | `Path.moveTo(x, y)` + `StrokeDescription(path, 0L, ~50L)` |
| Scroll ke bawah | `moveTo(x, yStart)` → `lineTo(x, yEnd)` dengan `yEnd < yStart`, durasi 300–800 ms |
| Thread | Loop di `Dispatchers.Default` + `delay()`; `dispatchGesture` di Main; hasil ke Dart lewat `runOnUiThread` |
| Headless | Loop milik service, bukan Activity/Dart. UI cukup `refresh()` saat `resumed` |

---

*Selamat belajar dan selamat membangun! Gunakan kemampuan otomasi ini secara bertanggung jawab.* 🚀
