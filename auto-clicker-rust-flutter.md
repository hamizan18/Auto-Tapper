# Membangun Auto Clicker Minimalis Berbasis Layar: Integrasi Rust dan Flutter

Dokumen ini membimbingmu membangun auto clicker yang sangat sederhana:

- **Flutter** hanya jadi **UI konfigurasi** (nama target, koordinat `(x, y)`, delay, tombol Mulai/Hentikan).
- **Rust** jadi **core engine**: loop klik, timing presisi, dan (di desktop) injeksi klik.
- **flutter_rust_bridge (FRB)** jadi jembatan antara Dart dan Rust.

## Daftar Isi

- [Baca Dulu: Gambaran Jujur Tentang Apa yang Bisa & Tidak Bisa](#baca-dulu-gambaran-jujur-tentang-apa-yang-bisa--tidak-bisa)
- [Modul 1: Konsep Native Bridge & Arsitektur Headless Auto Clicker](#modul-1-konsep-native-bridge--arsitektur-headless-auto-clicker)
- [Modul 2: Core Engine Rust (Otomasi & Simulasi Klik)](#modul-2-core-engine-rust-otomasi--simulasi-klik)
- [Modul 3: Komunikasi Flutter ke Rust (Passing Target & Kontrol Loop)](#modul-3-komunikasi-flutter-ke-rust-passing-target--kontrol-loop)
- [Modul 4: UI Konfigurasi Minimalis di Flutter](#modul-4-ui-konfigurasi-minimalis-di-flutter)
- [Penutup: Langkah Lanjutan & Troubleshooting](#penutup-langkah-lanjutan--troubleshooting)

---

## Baca Dulu: Gambaran Jujur Tentang Apa yang Bisa & Tidak Bisa

Sebelum menulis kode, pahami batasan platform supaya tidak salah arah:

| Platform | Siapa yang benar-benar "menekan layar"? | Peran Rust |
|----------|------------------------------------------|------------|
| **Android** | **Android Accessibility Service** (Kotlin) lewat `dispatchGesture`. Aplikasi biasa **tidak boleh** menyuntik sentuhan langsung tanpa root, dan Rust pun tidak punya jalan pintas. | Otak otomasi: loop, timing presisi, state start/stop. Rust mengirim "perintah klik" ke sisi Kotlin. |
| **Windows / macOS / Linux (X11)** | Rust sendiri lewat crate **`enigo`**. | Seluruhnya: loop + injeksi klik. |

Artinya, di Android, alurnya begini:

```text
Rust (loop + timing)  ──event "klik di (x,y)"──▶  Dart  ──MethodChannel──▶  Kotlin AccessibilityService  ──▶  Layar
```

Hal-hal lain yang perlu diketahui sejak awal:

- **"Deteksi input layar"** (mengenali tombol lewat tangkapan layar/pencocokan gambar) **di luar cakupan** dokumen ini. Kita memakai **koordinat manual**. Ide lanjutannya ada di bagian penutup.
- **"Background/overlay"**: Rust thread hidup di dalam proses aplikasimu. Supaya proses tidak dimatikan Android saat di background, nanti dibahas *foreground service* (langkah lanjutan).
- **Penggunaan yang bertanggung jawab:** pakai auto clicker hanya untuk aplikasi milikmu sendiri, keperluan aksesibilitas, atau pengujian. Banyak game dan layanan **melarang** otomasi di ToS mereka sehingga akunmu bisa kena sanksi. Selain itu, Google Play membatasi pemakaian Accessibility API untuk tujuan non-aksesibilitas, jadi proyek ini paling cocok untuk pemakaian pribadi atau *sideload*.
- Kode di dokumen ini belum dikompilasi di semua kombinasi versi. Versi library (FRB, enigo, dll.) berkembang cepat, jadi bila ada selisih nama/API, cek `docs.rs` dan dokumentasi FRB.

---

## Modul 1: Konsep Native Bridge & Arsitektur Headless Auto Clicker

### 1.1 Mengapa Rust untuk Timing & Event, Bukan Pure Dart?

| Aspek | Pure Dart | Rust |
|-------|-----------|------|
| Model eksekusi | Satu *event loop* per isolate. `Timer` baru jalan kalau event loop sedang longgar | **Thread OS sungguhan** yang berjalan mandiri dari UI |
| Jitter timing | `Timer.periodic` bisa tertunda saat UI sibuk (jank, GC) | Loop di thread khusus dengan `Instant` (jam monotonik) lebih stabil |
| Akses sistem | Terbatas (perlu plugin/FFI) | Akses langsung ke crate native (mis. `enigo`) |
| Keamanan konkurensi | Isolate tidak berbagi memori (aman, tapi harus kirim pesan) | `Send`/`Sync` + ownership: data race dicegah saat kompilasi |
| Biaya | Mudah, tanpa toolchain tambahan | Perlu toolchain Rust + build native |

Jujur-nya: untuk klik tiap 1 detik, Dart saja sudah cukup. Rust mulai terasa manfaatnya saat:

1. Interval pendek (puluhan ms) dan kamu ingin timing konsisten.
2. Kamu ingin **engine terpisah dari UI** supaya UI yang sibuk tidak mengganggu otomasi.
3. Kamu ingin satu engine yang sama dipakai di Android, Windows, macOS, dan Linux.

### 1.2 Dart FFI Mentah vs `flutter_rust_bridge` (FRB)

| | `dart:ffi` manual | `flutter_rust_bridge` v2 |
|---|---|---|
| Cara kerja | Tulis fungsi `extern "C"`, buat binding (`ffigen`/`cbindgen`) sendiri | Tulis fungsi Rust biasa, **kode jembatan di-generate otomatis** |
| Tipe data | Hanya tipe C (pointer, int, dll.), kelola memori sendiri | `String`, `Vec`, `Option`, `struct`, `enum` langsung dipakai |
| Async/thread | Manual | Fungsi non-sync otomatis jalan di thread pool Rust, Dart dapat `Future` |
| Stream (Rust → Dart) | Sulit | `StreamSink<T>` menjadi `Stream<T>` |
| Error | Kode error manual | `Result` menjadi exception Dart |
| Template Flutter | Tidak ada | Ada (`create`/`integrate`), build native diurus otomatis |

**Rekomendasi: pakai `flutter_rust_bridge` v2.** Ini pendekatan paling praktis dan matang untuk pemula. Dart FFI mentah bagus untuk dipahami konsepnya, tapi terlalu banyak kode boilerplate. *Native Assets / build hooks* milik Dart masih terus berkembang, jadi cek status terbarunya sebelum memakainya.

### 1.3 Setup Environment

**Prasyarat:**

1. Flutter SDK (`flutter doctor` harus hijau untuk target yang kamu pakai).
2. Rust via `rustup` (<https://rustup.rs>).
3. Android: **Android NDK** (pasang lewat Android Studio → SDK Manager → SDK Tools → NDK).
4. Desktop (untuk uji engine): Windows, macOS, atau Linux. Di Linux butuh paket pustaka X11/xdo untuk `enigo` (lihat README `enigo`).

**Buat proyek dari template FRB:**

```bash
cargo install flutter_rust_bridge_codegen
flutter_rust_bridge_codegen create auto_clicker
cd auto_clicker
```

Untuk proyek Flutter yang sudah ada, gunakan `flutter_rust_bridge_codegen integrate` di folder proyek tersebut.

**Struktur penting hasil template:**

```text
auto_clicker/
├── lib/
│   ├── main.dart
│   └── src/rust/              ← kode Dart hasil generate (jangan diedit manual)
├── rust/
│   ├── Cargo.toml
│   └── src/
│       ├── lib.rs
│       ├── api/               ← fungsi Rust di sini otomatis dijembatani ke Dart
│       │   ├── mod.rs
│       │   └── simple.rs
│       └── frb_generated.rs   ← hasil generate (jangan diedit manual)
├── flutter_rust_bridge.yaml
└── android/ ios/ windows/ ... ← folder platform Flutter
```

**Alur kerja harian:**

```bash
# 1. Edit kode Rust di rust/src/api/*.rs
# 2. Generate ulang jembatan:
flutter_rust_bridge_codegen generate
# (atau biarkan otomatis menunggu perubahan:)
flutter_rust_bridge_codegen generate --watch
# 3. Jalankan:
flutter run                 # Android
flutter run -d windows      # atau -d macos / -d linux
```

**Inisialisasi di Dart** (wajib sekali saat startup), `lib/main.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:auto_clicker/src/rust/frb_generated.dart';

Future<void> main() async {
  await RustLib.init();   // memuat library Rust & menyiapkan jembatan
  runApp(const MyApp());
}
```

> Nama paket (`auto_clicker`) mengikuti nama proyekmu. Sesuaikan di semua `import 'package:auto_clicker/...'`.

### 1.4 Arsitektur "Headless"

"Headless" berarti engine tidak butuh UI untuk bekerja. UI cuma **remote control**.

```text
┌───────────────────────┐
│ Flutter UI (Dart)     │  1 layar: label, x, y, delay, tombol Mulai/Hentikan
└──────────┬────────────┘
           │ startAutoClick(config)  /  stopAutoClick()      (FRB)
           ▼
┌───────────────────────┐
│ API Rust (api/…rs)    │  validasi config, menyimpan flag `running`
└──────────┬────────────┘
           │ spawn thread khusus
           ▼
┌───────────────────────┐        Stream<EngineEvent>
│ Worker Thread Rust    │ ─────────────────────────────▶ Dart (hitung klik, error, selesai)
│ loop: klik → tidur    │
│  • Desktop: enigo klik langsung
│  • Android: kirim event "klik di (x,y)"
└───────────────────────┘
                                   Dart ──MethodChannel──▶ Kotlin AccessibilityService.dispatchGesture
```

### 1.5 Pengenalan Izin OS

#### Android: Accessibility Service

Hanya **AccessibilityService** (dengan `canPerformGestures="true"`, Android 7.0/API 24+) yang bisa melakukan tap/swipe atas nama pengguna tanpa root. Pengguna **harus mengaktifkannya manual** di Pengaturan → Aksesibilitas. Aplikasi tidak bisa mengaktifkannya sendiri.

**File 1: `android/app/src/main/kotlin/com/example/auto_clicker/ClickAccessibilityService.kt`**

(Sesuaikan nama `package` dengan `applicationId` proyekmu.)

```kotlin
package com.example.auto_clicker

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.content.Intent
import android.graphics.Path
import android.view.accessibility.AccessibilityEvent

class ClickAccessibilityService : AccessibilityService() {

    companion object {
        // Diisi saat service aktif, null saat mati.
        @Volatile
        var instance: ClickAccessibilityService? = null
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
    }

    override fun onUnbind(intent: Intent?): Boolean {
        instance = null
        return super.onUnbind(intent)
    }

    override fun onDestroy() {
        instance = null
        super.onDestroy()
    }

    // Kita tidak membaca event layar, jadi dikosongkan.
    override fun onAccessibilityEvent(event: AccessibilityEvent?) {}
    override fun onInterrupt() {}

    /** Tap di koordinat layar (piksel). Mengembalikan true jika gesture diterima sistem. */
    fun tap(x: Int, y: Int): Boolean {
        val path = Path().apply { moveTo(x.toFloat(), y.toFloat()) }
        val stroke = GestureDescription.StrokeDescription(path, 0L, 50L) // mulai 0 ms, durasi 50 ms
        val gesture = GestureDescription.Builder().addStroke(stroke).build()
        return dispatchGesture(gesture, null, null)
    }
}
```

**File 2: `android/app/src/main/res/xml/accessibility_service_config.xml`** (buat folder `xml` jika belum ada)

```xml
<?xml version="1.0" encoding="utf-8"?>
<accessibility-service xmlns:android="http://schemas.android.com/apk/res/android"
    android:accessibilityEventTypes="typeWindowStateChanged"
    android:accessibilityFeedbackType="feedbackGeneric"
    android:canPerformGestures="true"
    android:notificationTimeout="100"
    android:description="@string/accessibility_description" />
```

**File 3: tambahkan di `android/app/src/main/res/values/strings.xml`** (buat file jika belum ada)

```xml
<resources>
    <string name="accessibility_description">Mengizinkan Auto Clicker melakukan ketukan pada koordinat yang kamu atur.</string>
</resources>
```

**File 4: daftarkan di `android/app/src/main/AndroidManifest.xml`** (di dalam tag `<application>`, sejajar dengan `<activity>`):

```xml
<service
    android:name=".ClickAccessibilityService"
    android:exported="true"
    android:permission="android.permission.BIND_ACCESSIBILITY_SERVICE">
    <intent-filter>
        <action android:name="android.accessibilityservice.AccessibilityService" />
    </intent-filter>
    <meta-data
        android:name="android.accessibilityservice"
        android:resource="@xml/accessibility_service_config" />
</service>
```

**Mengaktifkan di HP:** Pengaturan → Aksesibilitas → (Aplikasi terinstal / Layanan terunduh) → pilih aplikasimu → aktifkan.

> Pada Android 13+, aplikasi hasil *sideload* (bukan dari Play Store) bisa memblokir tombol aktifkan dengan pesan **"Restricted setting"**. Solusinya: buka Info Aplikasi → menu ⋮ → **Izinkan setelan terbatas**, lalu aktifkan lagi.

#### Izin tambahan (untuk langkah lanjutan)

| Kebutuhan | Izin / mekanisme |
|-----------|------------------|
| Jalan stabil di background | Foreground Service + notifikasi (`FOREGROUND_SERVICE`, dan `POST_NOTIFICATIONS` di Android 13+) |
| Tombol mengambang (overlay) | `SYSTEM_ALERT_WINDOW` ("Tampilkan di atas aplikasi lain") |

#### Desktop

| OS | Catatan izin |
|----|--------------|
| Windows | Biasanya tanpa izin khusus. Klik **tidak** masuk ke jendela yang berjalan sebagai Administrator (UIPI) kecuali aplikasimu juga Administrator. |
| macOS | Wajib izin **Accessibility**: System Settings → Privacy & Security → Accessibility → izinkan aplikasimu/terminalmu. |
| Linux | X11 bekerja. **Wayland** membatasi injeksi input, jadi `enigo` bisa tidak bekerja penuh. Uji di sesi X11. |

---

### 1.6 Tugas Praktik (Ganti Baris Kode)

**Cuplikan A, `accessibility_service_config.xml`:**

```xml
<accessibility-service xmlns:android="http://schemas.android.com/apk/res/android"
    android:accessibilityEventTypes="typeWindowStateChanged"
    android:accessibilityFeedbackType="feedbackGeneric"
    android:canPerformGestures="false"
    android:notificationTimeout="100"
    android:description="@string/accessibility_description" />
```

Ganti baris `android:canPerformGestures="false"` menjadi `android:canPerformGestures="true"` agar service diizinkan memanggil `dispatchGesture` untuk melakukan tap.

**Cuplikan B, `rust/src/api/simple.rs`:**

```rust
fn versi_engine() -> String {
    format!("AutoClicker core v{}", env!("CARGO_PKG_VERSION"))
}
```

Ganti baris `fn versi_engine() -> String {` menjadi `pub fn versi_engine() -> String {` agar codegen FRB mengenali fungsi ini dan membuatkan binding Dart-nya.

**Cuplikan C, `lib/main.dart`:**

```dart
void main() {
  runApp(const MyApp());
}
```

1. Ganti baris `void main() {` menjadi `Future<void> main() async {` agar kita boleh memakai `await` di dalam `main`.
2. Ganti baris `runApp(const MyApp());` menjadi dua baris: `await RustLib.init();` lalu `runApp(const MyApp());` agar jembatan Rust siap sebelum UI memanggil fungsi Rust apa pun. (Tambahkan juga `import 'package:auto_clicker/src/rust/frb_generated.dart';` di atas file.)

<details>
<summary>Lihat Solusi & Penjelasan</summary>

**Cuplikan A (hasil):**

```xml
<accessibility-service xmlns:android="http://schemas.android.com/apk/res/android"
    android:accessibilityEventTypes="typeWindowStateChanged"
    android:accessibilityFeedbackType="feedbackGeneric"
    android:canPerformGestures="true"
    android:notificationTimeout="100"
    android:description="@string/accessibility_description" />
```

Tanpa `canPerformGestures="true"`, `dispatchGesture()` akan gagal (mengembalikan `false`) karena Android menganggap service-mu tidak mendeklarasikan kemampuan gesture. Deklarasi ini juga yang ditampilkan ke pengguna sebagai kemampuan service saat meminta izin.

**Cuplikan B (hasil):**

```rust
pub fn versi_engine() -> String {
    format!("AutoClicker core v{}", env!("CARGO_PKG_VERSION"))
}
```

FRB hanya membuat binding untuk item **publik** di folder `rust/src/api/`. Fungsi tanpa `pub` itu privat untuk modulnya, sehingga tidak muncul di Dart. Setelah mengubahnya, jalankan `flutter_rust_bridge_codegen generate`.

**Cuplikan C (hasil):**

```dart
import 'package:flutter/material.dart';
import 'package:auto_clicker/src/rust/frb_generated.dart';

Future<void> main() async {
  await RustLib.init();
  runApp(const MyApp());
}
```

`RustLib.init()` memuat library native dan menyiapkan *thread pool* serta kanal komunikasi. Ia bersifat `async`, jadi `main` harus `async`. Kalau lupa, pemanggilan fungsi Rust pertama akan melempar error bahwa jembatan belum diinisialisasi.

</details>

---

### 1.7 Tantangan "Fix the Syntax" (Debug Challenge)

Ini contoh binding `dart:ffi` mentah (supaya kamu paham apa yang diotomatiskan FRB). Kode ini punya kesalahan pada deklarasi tipe.

```dart
import 'dart:ffi';

// Fungsi C di sisi native: int32_t hitung_klik(int32_t a, int32_t b);
typedef NativeHitung = int Function(int a, int b);
typedef DartHitung = int Function(int a, int b);

int jalankan(DynamicLibrary lib) {
  final hitung = lib.lookupFunction<NativeHitung, DartHitung>('hitung_klik');
  return hitung(1, 2);
}
```

**Simulasi pesan error `dart analyze` / compiler (redaksi persisnya bisa berbeda antar versi Dart):**

```text
error • lib/ffi_demo.dart:8:41 • The type 'int Function(int, int)' given to
        'DynamicLibrary.lookupFunction' must be a valid 'dart:ffi' native
        function signature. Use native types such as 'Int32' instead of 'int'.
```

<details>
<summary>Perbaikan Sintaks & Pembahasan</summary>

```dart
import 'dart:ffi';

// Sisi native: gunakan tipe NATIVE dari dart:ffi (Int32, Int64, Double, Pointer, ...)
typedef NativeHitung = Int32 Function(Int32 a, Int32 b);
// Sisi Dart: gunakan tipe Dart biasa (int, double, ...)
typedef DartHitung = int Function(int a, int b);

int jalankan(DynamicLibrary lib) {
  final hitung = lib.lookupFunction<NativeHitung, DartHitung>('hitung_klik');
  return hitung(1, 2);
}
```

**Penyebab:** `lookupFunction` butuh **dua** typedef: signature **native** (cara C melihat fungsi tersebut: `Int32`, `Double`, `Pointer<...>`) dan signature **Dart** (cara Dart memanggilnya: `int`, `double`). Pada kode di atas, typedef native ditulis memakai `int`, padahal `int` bukan tipe native. Kamu harus menyebut lebar bit-nya (`Int32`) karena C membedakan `int32_t` dan `int64_t`.

**Pelajaran:** inilah salah satu alasan kita memakai FRB. Ia menghasilkan pasangan typedef ini (dan konversi string/struct/memori) otomatis sehingga kesalahan seperti ini hampir tidak mungkin terjadi.

</details>

---

## Modul 2: Core Engine Rust (Otomasi & Simulasi Klik)

Di modul ini kita membangun engine **tanpa tahu apa pun tentang Flutter**. Pemisahan ini disengaja: engine bisa diuji sendiri, dan jembatan FRB (Modul 3) hanyalah "kulit" tipis di atasnya.

### 2.1 Pembagian Thread (Penting untuk Menghindari ANR/Freeze)

Ada beberapa thread yang terlibat. Pahami peran masing-masing:

| Thread | Menjalankan apa | Kalau diblokir lama… |
|--------|-----------------|----------------------|
| **Android Main/Platform thread** | Kode Kotlin: handler `MethodChannel`, `dispatchGesture` | **ANR** ("Application Not Responding") jika input tak dilayani >~5 detik |
| **Flutter UI thread (isolate utama Dart)** | `build()`, `setState`, listener `Stream`, pemanggilan fungsi bridge | **UI membeku/jank** |
| **FRB worker thread pool (Rust)** | Fungsi Rust non-sync yang dipanggil dari Dart | Pool terpakai habis, panggilan lain mengantre |
| **`autoclick-worker` (thread kita sendiri)** | Loop klik: klik → tidur → ulang | Tidak ada masalah, memang tugasnya |

**Aturan emas anti-freeze:**

1. **Jangan pernah** menaruh loop panjang/`sleep` di fungsi Rust yang ditandai `#[frb(sync)]`. Fungsi sync berjalan **langsung di thread UI Dart**, jadi loop di sana = UI beku (di Android bisa berujung ANR).
2. **Jangan** menjalankan `loop {}` tanpa akhir di fungsi API biasa. Fungsi itu menempati thread pool FRB selamanya. Cukup **spawn thread khusus** lalu fungsi API langsung `return`.
3. Komunikasi antar thread lewat **`Arc<AtomicBool>`** (flag berhenti) dan **callback/stream** (kirim event). Jangan berbagi variabel biasa.
4. Thread loop harus **sering mengecek flag berhenti**. Kita tidur dalam potongan kecil (≤ 50 ms) agar tombol "Hentikan" responsif walau interval klik panjang.

### 2.2 Crates yang Dipakai

`rust/Cargo.toml`:

```toml
[package]
name = "rust_lib_auto_clicker"
version = "0.1.0"
edition = "2021"

[lib]
crate-type = ["cdylib", "staticlib"]

[dependencies]
# Biarkan versi flutter_rust_bridge persis seperti yang ditulis template
# (versi ini harus SAMA dengan versi flutter_rust_bridge_codegen).
flutter_rust_bridge = "=2.x.x"
anyhow = "1"

# enigo hanya untuk desktop. Tidak mendukung Android, jadi dibatasi lewat cfg.
[target.'cfg(any(target_os = "windows", target_os = "macos", target_os = "linux"))'.dependencies]
enigo = "0.3"
```

> `"=2.x.x"` hanyalah penanda. Template FRB mengisi versi persisnya otomatis, jangan diubah manual. Cek versi `enigo` terbaru di <https://docs.rs/enigo>; API di bawah mengikuti seri 0.3.

### 2.3 Lapisan Injeksi Klik: `injector.rs`

Satu antarmuka (`Injector`), dua implementasi sesuai platform. `rust/src/injector.rs`:

```rust
use anyhow::Result;

// ---------- Desktop: klik sungguhan lewat enigo ----------
#[cfg(any(target_os = "windows", target_os = "macos", target_os = "linux"))]
pub struct Injector {
    enigo: enigo::Enigo,
}

#[cfg(any(target_os = "windows", target_os = "macos", target_os = "linux"))]
impl Injector {
    pub fn new() -> Result<Self> {
        use enigo::{Enigo, Settings};
        let enigo = Enigo::new(&Settings::default())
            .map_err(|e| anyhow::anyhow!("Gagal menginisialisasi enigo: {e}"))?;
        Ok(Self { enigo })
    }

    /// Pindahkan kursor ke (x, y) absolut lalu klik kiri.
    pub fn click(&mut self, x: i32, y: i32) -> Result<()> {
        use enigo::{Button, Coordinate, Direction, Mouse};
        self.enigo
            .move_mouse(x, y, Coordinate::Abs)
            .map_err(|e| anyhow::anyhow!("Gagal memindahkan kursor: {e}"))?;
        self.enigo
            .button(Button::Left, Direction::Click)
            .map_err(|e| anyhow::anyhow!("Gagal mengklik: {e}"))?;
        Ok(())
    }
}

// ---------- Android/iOS: tidak ada injeksi di Rust ----------
// Klik dikirim sebagai event ke Dart, lalu dieksekusi AccessibilityService (Kotlin).
#[cfg(not(any(target_os = "windows", target_os = "macos", target_os = "linux")))]
pub struct Injector;

#[cfg(not(any(target_os = "windows", target_os = "macos", target_os = "linux")))]
impl Injector {
    pub fn new() -> Result<Self> {
        Ok(Self)
    }

    pub fn click(&mut self, _x: i32, _y: i32) -> Result<()> {
        Ok(())
    }
}
```

> **Kenapa `Injector` dibuat di dalam thread worker, bukan di luar?** Di beberapa platform `Enigo` memegang handle native yang tidak aman dipindah antar thread (tidak `Send`). Dengan membuatnya di thread yang memakainya, masalah itu tidak muncul sama sekali.

### 2.4 Engine Loop: `engine.rs`

`rust/src/engine.rs`:

```rust
use std::io;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use crate::injector::Injector;

/// Pengaturan murni untuk engine (belum ada hubungan dengan Flutter).
#[derive(Debug, Clone)]
pub struct LoopSettings {
    pub x: i32,
    pub y: i32,
    pub interval_ms: u32,
    pub max_clicks: Option<u32>, // None = tanpa batas
}

/// Kejadian yang dilaporkan loop ke pemanggil.
#[derive(Debug)]
pub enum LoopEvent {
    Click { index: u32, x: i32, y: i32 },
    Failed(String),
    Stopped { total_clicks: u32 },
}

/// Menjalankan loop di thread baru lalu LANGSUNG kembali (tidak memblokir pemanggil).
/// `on_event` mengembalikan `false` jika pemanggil tidak peduli lagi (loop akan berhenti).
pub fn spawn_click_loop<F>(
    settings: LoopSettings,
    running: Arc<AtomicBool>,
    on_event: F,
) -> io::Result<JoinHandle<()>>
where
    F: Fn(LoopEvent) -> bool + Send + 'static,
{
    thread::Builder::new()
        .name("autoclick-worker".into())
        .spawn(move || run_loop(settings, running, on_event))
}

fn run_loop<F>(settings: LoopSettings, running: Arc<AtomicBool>, on_event: F)
where
    F: Fn(LoopEvent) -> bool,
{
    // Dibuat DI DALAM thread ini (lihat catatan di injector.rs).
    let mut injector = match Injector::new() {
        Ok(i) => i,
        Err(e) => {
            running.store(false, Ordering::SeqCst);
            on_event(LoopEvent::Failed(e.to_string()));
            return;
        }
    };

    let interval = Duration::from_millis(settings.interval_ms as u64);
    let start = Instant::now();
    let mut index: u32 = 0;

    while running.load(Ordering::SeqCst) {
        if let Some(max) = settings.max_clicks {
            if index >= max {
                break;
            }
        }

        if let Err(e) = injector.click(settings.x, settings.y) {
            on_event(LoopEvent::Failed(e.to_string()));
            break;
        }
        index += 1;

        let lanjut = on_event(LoopEvent::Click {
            index,
            x: settings.x,
            y: settings.y,
        });
        if !lanjut {
            break;
        }

        // Jadwal absolut: klik ke-N dijadwalkan di start + N * interval.
        // Cara ini mencegah "drift" (waktu kumulatif yang makin melenceng).
        sleep_until(start + interval * index, &running);
    }

    running.store(false, Ordering::SeqCst);
    on_event(LoopEvent::Stopped { total_clicks: index });
}

/// Tidur sampai `deadline`, tapi dipotong-potong maksimal 50 ms
/// supaya flag `running` yang berubah jadi false cepat dikenali.
fn sleep_until(deadline: Instant, running: &AtomicBool) {
    while running.load(Ordering::SeqCst) {
        let now = Instant::now();
        if now >= deadline {
            return;
        }
        let sisa = deadline - now;
        thread::sleep(sisa.min(Duration::from_millis(50)));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sleep_until_langsung_keluar_saat_flag_false() {
        let running = AtomicBool::new(false);
        let mulai = Instant::now();
        sleep_until(mulai + Duration::from_secs(5), &running);
        assert!(mulai.elapsed() < Duration::from_millis(100));
    }
}
```

Daftarkan modul di `rust/src/lib.rs`:

```rust
mod api;
mod engine;
mod frb_generated; /* AUTO INJECTED BY flutter_rust_bridge. This line may not be accurate, and you can change it according to your needs. */
mod injector;
```

Uji bagian yang aman (tanpa mengklik layar sungguhan):

```bash
cd rust
cargo test
```

### 2.5 Mengapa Desainnya Begini?

- **`Arc<AtomicBool>`**: flag yang bisa dibaca thread worker dan ditulis thread lain. `Arc` = pemilik bersama, `AtomicBool` = baca/tulis aman tanpa mutex.
- **Jadwal absolut (`start + interval * index`)**: kalau memakai `sleep(interval)` murni, waktu eksekusi klik itu sendiri ikut menambah delay dan lama-lama melenceng.
- **Callback `on_event`**: engine tidak peduli ke mana event dikirim (stream Flutter, log, test). Inilah yang membuatnya mudah dihubungkan di Modul 3.
- **`move` + `'static`**: thread yang di-*spawn* bisa hidup lebih lama dari fungsi yang membuatnya, jadi semua data yang dipakai harus **dimiliki** thread tersebut.

---

### 2.6 Tugas Praktik (Ganti Baris Kode)

Cuplikan berikut adalah versi awal loop yang masih sederhana:

```rust
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant};

fn sleep_until(deadline: Instant, running: &AtomicBool) {
    while running.load(Ordering::SeqCst) {
        let now = Instant::now();
        if now >= deadline {
            return;
        }
        thread::sleep((deadline - now).min(Duration::from_millis(50)));
    }
}

fn run_loop(interval_ms: u32, max_clicks: u32, running: Arc<AtomicBool>) {
    let interval = Duration::from_millis(interval_ms as u64);
    let start = Instant::now();
    let mut index: u32 = 0;

    while running.load(Ordering::SeqCst) {
        println!("klik ke-{}", index);
        index += 1;

        thread::sleep(interval);
    }
}
```

1. Ganti baris `thread::sleep(interval);` menjadi `sleep_until(start + interval * index, &running);` agar jadwal klik memakai waktu absolut (tanpa drift) dan tombol berhenti tetap responsif.
2. Ganti baris `while running.load(Ordering::SeqCst) {` menjadi `while running.load(Ordering::SeqCst) && index < max_clicks {` agar loop berhenti otomatis setelah jumlah klik maksimum tercapai.

<details>
<summary>Lihat Solusi & Penjelasan</summary>

```rust
fn run_loop(interval_ms: u32, max_clicks: u32, running: Arc<AtomicBool>) {
    let interval = Duration::from_millis(interval_ms as u64);
    let start = Instant::now();
    let mut index: u32 = 0;

    while running.load(Ordering::SeqCst) && index < max_clicks {
        println!("klik ke-{}", index);
        index += 1;

        sleep_until(start + interval * index, &running);
    }
}
```

**Pembahasan perubahan 1 (`sleep_until`):**

- `thread::sleep(interval)` tidur **utuh** selama `interval`. Dua masalah: (a) kalau interval 10 detik, tombol Hentikan baru dikenali setelah 10 detik; (b) waktu proses di dalam loop ditambahkan ke setiap putaran sehingga jadwal lama-lama melenceng (*drift*).
- `sleep_until(start + interval * index, ...)` menghitung **tenggat absolut** untuk klik berikutnya dan tidur dalam potongan ≤ 50 ms sambil mengecek flag `running`.
- `interval * index` valid karena `Duration` mengimplementasikan perkalian dengan `u32`, makanya `index` bertipe `u32`.

**Pembahasan perubahan 2 (`index < max_clicks`):**

- Kondisi loop kini dua syarat: masih diminta berjalan (`running`) **dan** belum mencapai batas. Operator `&&` melakukan *short-circuit*: jika `running` sudah `false`, sisi kanan tidak dievaluasi.
- Pada engine sungguhan (Bagian 2.4) kita memakai `Option<u32>` agar "tanpa batas" bisa dinyatakan dengan `None`.

</details>

---

### 2.7 Tantangan "Fix the Syntax" (Debug Challenge)

Fungsi ini ingin memulai loop di thread baru dan mengembalikan flag untuk menghentikannya. Kode ini **tidak bisa dikompilasi**.

```rust
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::Duration;

fn mulai(interval_ms: u64) -> Arc<AtomicBool> {
    let running = Arc::new(AtomicBool::new(true));
    let stop_handle = running.clone();

    thread::spawn(|| {
        while running.load(Ordering::SeqCst) {
            println!("klik!");
            thread::sleep(Duration::from_millis(interval_ms));
        }
    });

    stop_handle
}
```

**Simulasi pesan error `rustc`:**

```text
error[E0373]: closure may outlive the current function, but it borrows `running`, which is owned by the current function
  --> src/main.rs:10:19
   |
10 |     thread::spawn(|| {
   |                   ^^ may outlive borrowed value `running`
11 |         while running.load(Ordering::SeqCst) {
   |               ------- `running` is borrowed here
   |
note: function requires argument type to outlive `'static`
help: to force the closure to take ownership of `running` (and any other referenced variables), use the `move` keyword
   |
10 |     thread::spawn(move || {
   |                   ++++
```

<details>
<summary>Perbaikan Sintaks & Pembahasan</summary>

```rust
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::Duration;

fn mulai(interval_ms: u64) -> Arc<AtomicBool> {
    let running = Arc::new(AtomicBool::new(true));
    let stop_handle = running.clone();

    thread::spawn(move || {
        while running.load(Ordering::SeqCst) {
            println!("klik!");
            thread::sleep(Duration::from_millis(interval_ms));
        }
    });

    stop_handle
}
```

**Penyebab:** `thread::spawn` meminta closure yang berumur `'static`, karena thread baru bisa terus hidup setelah fungsi `mulai` selesai. Closure tanpa `move` hanya **meminjam** `running` dan `interval_ms` dari stack fungsi `mulai`. Begitu fungsi itu return, stack-nya hilang dan pinjaman menjadi *dangling*. Borrow checker mencegahnya sejak kompilasi.

**Solusi:** `move` memindahkan kepemilikan variabel yang dipakai ke dalam closure (`running` dipindahkan, `interval_ms` yang bertipe `Copy` disalin). Karena itu kita membuat `stop_handle` (hasil `clone()` dari `Arc`) **sebelum** `move`: satu pegangan untuk thread, satu untuk pemanggil. Keduanya menunjuk ke `AtomicBool` yang sama.

</details>

---

## Modul 3: Komunikasi Flutter ke Rust (Passing Target & Kontrol Loop)

### 3.1 Aturan Pemetaan Tipe FRB (Ringkas)

| Rust | Dart |
|------|------|
| `i32`, `u32` | `int` |
| `f64` | `double` |
| `bool` | `bool` |
| `String` | `String` |
| `Option<T>` | `T?` |
| `Vec<T>` | `List<T>` |
| `u64` (dan tipe 64-bit tertentu) | `BigInt` ⚠️ (hati-hati!) |
| `struct` | `class` |
| `enum` dengan data | *sealed class* (mis. `EngineEvent_Click`) |
| `StreamSink<T>` (parameter) | fungsi mengembalikan `Stream<T>` |
| `anyhow::Result<T>` | `Future<T>` yang melempar exception jika gagal |

Karena itu di dokumen ini semua angka memakai **`u32`/`i32`**, supaya di Dart tetap `int` biasa.

### 3.2 File API: `rust/src/api/auto_click.rs`

Daftarkan dulu di `rust/src/api/mod.rs`:

```rust
pub mod auto_click;
pub mod simple;
```

Isi `rust/src/api/auto_click.rs`:

```rust
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use anyhow::{bail, Result};
use flutter_rust_bridge::frb;

use crate::engine::{spawn_click_loop, LoopEvent, LoopSettings};
use crate::frb_generated::StreamSink;

/// Konfigurasi yang dikirim dari UI Flutter.
pub struct ClickConfig {
    pub label: String,           // nama/identitas tombol target (untuk tampilan & log)
    pub x: i32,                  // koordinat layar (piksel)
    pub y: i32,
    pub interval_ms: u32,        // jeda antar klik
    pub max_clicks: Option<u32>, // None = tanpa batas
}

/// Kejadian dari engine yang dikirim ke Flutter sebagai Stream.
pub enum EngineEvent {
    Click { index: u32, x: i32, y: i32 },
    Stopped { total_clicks: u32 },
    Failed { message: String },
}

/// Status engine saat ini.
pub struct EngineStatus {
    pub is_running: bool,
    pub label: Option<String>,
}

struct ActiveRun {
    running: Arc<AtomicBool>,
    label: String,
}

// Satu engine global. Mutex menjaga akses dari banyak thread tetap aman.
static ENGINE: Mutex<Option<ActiveRun>> = Mutex::new(None);

/// Mulai otomasi. Fungsi ini TIDAK memblokir: ia hanya men-spawn thread lalu kembali.
/// Di Dart fungsi ini menjadi `Stream<EngineEvent> startAutoClick({required ClickConfig config})`.
pub fn start_auto_click(config: ClickConfig, events: StreamSink<EngineEvent>) -> Result<()> {
    if config.interval_ms < 10 {
        bail!("Delay minimal 10 ms (disarankan >= 100 ms di Android).");
    }
    if config.x < 0 || config.y < 0 {
        bail!("Koordinat tidak boleh negatif.");
    }

    // `unwrap_or_else(into_inner)` tetap memakai data meski mutex "poisoned"
    // (thread lain panic saat memegang kunci).
    let mut slot = ENGINE.lock().unwrap_or_else(|e| e.into_inner());

    if let Some(active) = slot.as_ref() {
        if active.running.load(Ordering::SeqCst) {
            bail!("Engine sudah berjalan.");
        }
    }

    let running = Arc::new(AtomicBool::new(true));
    *slot = Some(ActiveRun {
        running: running.clone(),
        label: config.label.clone(),
    });

    let settings = LoopSettings {
        x: config.x,
        y: config.y,
        interval_ms: config.interval_ms,
        max_clicks: config.max_clicks,
    };

    // Jembatan: LoopEvent (internal engine) -> EngineEvent (dikirim ke Dart).
    let kirim = move |event: LoopEvent| -> bool {
        let dipetakan = match event {
            LoopEvent::Click { index, x, y } => EngineEvent::Click { index, x, y },
            LoopEvent::Stopped { total_clicks } => EngineEvent::Stopped { total_clicks },
            LoopEvent::Failed(message) => EngineEvent::Failed { message },
        };
        // add() gagal jika sisi Dart sudah berhenti mendengarkan -> engine ikut berhenti.
        events.add(dipetakan).is_ok()
    };

    spawn_click_loop(settings, running, kirim)?;
    Ok(())
}

/// Hentikan otomasi. Sinkron & instan (hanya mengubah flag).
#[frb(sync)]
pub fn stop_auto_click() {
    let guard = ENGINE.lock().unwrap_or_else(|e| e.into_inner());
    if let Some(active) = guard.as_ref() {
        active.running.store(false, Ordering::SeqCst);
    }
}

/// Status saat ini (sinkron & instan).
#[frb(sync)]
pub fn get_engine_status() -> EngineStatus {
    let guard = ENGINE.lock().unwrap_or_else(|e| e.into_inner());
    match guard.as_ref() {
        Some(active) => EngineStatus {
            is_running: active.running.load(Ordering::SeqCst),
            label: Some(active.label.clone()),
        },
        None => EngineStatus {
            is_running: false,
            label: None,
        },
    }
}
```

Setelah menyimpan, jalankan:

```bash
flutter_rust_bridge_codegen generate
```

### 3.3 Kenapa `start` Non-Sync, tapi `stop` Sync?

| Fungsi | Mode | Alasan |
|--------|------|--------|
| `start_auto_click` | **Non-sync** (default) | Dijalankan di thread pool FRB, bukan di thread UI. Aman walau ada kerja tambahan (mengunci mutex, membuat thread). |
| `stop_auto_click` | **`#[frb(sync)]`** | Hanya mengubah satu flag atomik, selesai dalam mikrodetik. Tak perlu `await`, tombol Hentikan langsung bekerja. |
| `get_engine_status` | **`#[frb(sync)]`** | Sama: baca cepat. |

> Gunakan `#[frb(sync)]` **hanya** untuk fungsi yang pasti selesai sangat cepat. Fungsi sync berjalan di thread UI Dart.

### 3.4 Memakainya dari Dart

```dart
import 'package:auto_clicker/src/rust/api/auto_click.dart';

// Mulai: hasilnya Stream
final stream = startAutoClick(
  config: ClickConfig(
    label: 'Tombol Play',
    x: 540,
    y: 1200,
    intervalMs: 200,
    // maxClicks: 100,  // hilangkan komentar untuk membatasi jumlah klik
  ),
);

final sub = stream.listen((event) {
  switch (event) {
    case EngineEvent_Click(:final index):
      debugPrint('Klik ke-$index');
    case EngineEvent_Stopped(:final totalClicks):
      debugPrint('Selesai, total $totalClicks klik');
    case EngineEvent_Failed(:final message):
      debugPrint('Gagal: $message');
  }
});

// Berhenti (sinkron, tanpa await)
stopAutoClick();

// Cek status
final status = getEngineStatus();
debugPrint('Berjalan? ${status.isRunning}');
```

> Nama kelas/field hasil generate (mis. `EngineEvent_Click`) mengikuti versi FRB yang kamu pakai. Jika berbeda, buka file hasil generate di `lib/src/rust/api/auto_click.dart` dan sesuaikan.

### 3.5 Alur Start/Stop

```text
[Dart] tekan "Mulai"
   └─▶ startAutoClick(config)                 (thread pool FRB)
         ├─ validasi config
         ├─ buat Arc<AtomicBool>(true)  → simpan di ENGINE
         └─ spawn thread "autoclick-worker" ──▶ loop klik (thread sendiri)
                                                    │ tiap klik: events.add(Click)
[Dart] Stream menerima Click ◀────────────────────┘

[Dart] tekan "Hentikan"
   └─▶ stopAutoClick()                        (sync, instan)
         └─ flag = false ──▶ worker keluar dari loop ──▶ events.add(Stopped) ──▶ [Dart] UI kembali ke "Mulai"
```

---

### 3.6 Tugas Praktik (Ganti Baris Kode)

Cuplikan awal fungsi stop:

```rust
use std::sync::atomic::Ordering;

pub fn stop_auto_click() {
    let guard = ENGINE.lock().unwrap();
    if let Some(active) = guard.as_ref() {
        active.running.store(false, Ordering::SeqCst);
    }
}
```

1. Ganti baris `pub fn stop_auto_click() {` menjadi dua baris: `#[frb(sync)]` lalu `pub fn stop_auto_click() {` (dan tambahkan `use flutter_rust_bridge::frb;` di bagian atas) agar di Dart fungsi ini bisa dipanggil langsung tanpa `await` dan efeknya instan.
2. Ganti baris `let guard = ENGINE.lock().unwrap();` menjadi `let guard = ENGINE.lock().unwrap_or_else(|e| e.into_inner());` agar tombol Hentikan tetap berfungsi walau mutex ter-*poison* akibat panic di thread lain.

<details>
<summary>Lihat Solusi & Penjelasan</summary>

```rust
use std::sync::atomic::Ordering;
use flutter_rust_bridge::frb;

#[frb(sync)]
pub fn stop_auto_click() {
    let guard = ENGINE.lock().unwrap_or_else(|e| e.into_inner());
    if let Some(active) = guard.as_ref() {
        active.running.store(false, Ordering::SeqCst);
    }
}
```

**Pembahasan 1 (`#[frb(sync)]`):** tanpa atribut ini, FRB menghasilkan `Future<void> stopAutoClick()` (jalan di thread pool). Itu berfungsi, tapi kamu harus `await`, dan ada jeda kecil antrean pool. Untuk operasi yang hanya mengubah satu flag, versi sync lebih tepat dan membuat tombol Hentikan terasa instan. Ingat syaratnya: fungsi sync wajib sangat cepat karena berjalan di thread UI.

**Pembahasan 2 (`unwrap_or_else(|e| e.into_inner())`):** `Mutex::lock()` mengembalikan `Err` jika mutex *poisoned* (ada thread yang panic saat memegang kunci). `unwrap()` akan ikut panic, sehingga tombol Hentikan malah crash. `PoisonError::into_inner()` tetap memberikan data di dalamnya. Aman di sini karena data kita hanya flag dan label sederhana.

</details>

---

### 3.7 Tantangan "Fix the Syntax" (Debug Challenge)

Misalkan kamu menulis `interval_ms: u64` di struct `ClickConfig` Rust, lalu menjalankan codegen. Kode Dart di bawah ini **tidak lolos analisis**.

```dart
// Hasil generate dari Rust (interval_ms: u64) ->  final BigInt intervalMs;
import 'package:auto_clicker/src/rust/api/auto_click.dart';

Stream<EngineEvent> mulaiKlik() {
  return startAutoClick(
    config: ClickConfig(
      label: 'Tombol Play',
      x: 540,
      y: 1200,
      intervalMs: 100,
    ),
  );
}
```

**Simulasi pesan error `dart analyze`:**

```text
error • lib/main.dart:10:19 • The argument type 'int' can't be assigned to the
        parameter type 'BigInt'. • argument_type_not_assignable
```

<details>
<summary>Perbaikan Sintaks & Pembahasan</summary>

**Opsi 1 (disarankan): ubah tipe di Rust ke `u32`, lalu generate ulang.**

```rust
pub struct ClickConfig {
    pub label: String,
    pub x: i32,
    pub y: i32,
    pub interval_ms: u32,        // u64 -> u32
    pub max_clicks: Option<u32>,
}
```

```bash
flutter_rust_bridge_codegen generate
```

Kode Dart di atas lalu valid apa adanya karena `intervalMs` sekarang `int`.

**Opsi 2: tetap `u64`, kirim `BigInt` dari Dart.**

```dart
config: ClickConfig(
  label: 'Tombol Play',
  x: 540,
  y: 1200,
  intervalMs: BigInt.from(100),
),
```

**Penyebab:** FRB memetakan tipe 64-bit tak bertanda (`u64`) ke `BigInt` di Dart karena `int` Dart tidak bisa merepresentasikan seluruh rentang `u64`, terutama di Web. Kamu perlu sadar akan hal ini setiap mendefinisikan tipe di Rust. Untuk nilai kecil seperti delay milidetik dan koordinat layar, `u32`/`i32` sudah lebih dari cukup dan lebih nyaman dipakai di Dart.

</details>

---

## Modul 4: UI Konfigurasi Minimalis di Flutter

### 4.1 Sisi Native Android: Jembatan Dart → Kotlin

Di Android, event `Click` dari Rust harus berubah menjadi tap sungguhan. Jembatan terakhir ini memakai `MethodChannel` biasa.

**`android/app/src/main/kotlin/com/example/auto_clicker/MainActivity.kt`:**

```kotlin
package com.example.auto_clicker

import android.content.Intent
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "autoclicker/gesture")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isServiceEnabled" ->
                        result.success(ClickAccessibilityService.instance != null)

                    "openSettings" -> {
                        startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
                        result.success(null)
                    }

                    "tap" -> {
                        val x = call.argument<Int>("x") ?: 0
                        val y = call.argument<Int>("y") ?: 0
                        val service = ClickAccessibilityService.instance
                        if (service == null) {
                            result.error("NO_SERVICE", "Accessibility service belum aktif", null)
                        } else {
                            result.success(service.tap(x, y))
                        }
                    }

                    else -> result.notImplemented()
                }
            }
    }
}
```

**`lib/android_clicker.dart`:**

```dart
import 'package:flutter/services.dart';

/// Pembungkus MethodChannel ke AccessibilityService (hanya dipakai di Android).
class AndroidClicker {
  static const MethodChannel _channel = MethodChannel('autoclicker/gesture');

  static Future<bool> isServiceEnabled() async {
    return await _channel.invokeMethod<bool>('isServiceEnabled') ?? false;
  }

  static Future<void> openSettings() async {
    await _channel.invokeMethod<void>('openSettings');
  }

  static Future<bool> tap(int x, int y) async {
    return await _channel.invokeMethod<bool>('tap', {'x': x, 'y': y}) ?? false;
  }
}
```

### 4.2 UI Satu Layar: `lib/main.dart`

```dart
import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import 'package:auto_clicker/android_clicker.dart';
import 'package:auto_clicker/src/rust/api/auto_click.dart';
import 'package:auto_clicker/src/rust/frb_generated.dart';

Future<void> main() async {
  await RustLib.init();
  runApp(const AutoClickerApp());
}

class AutoClickerApp extends StatelessWidget {
  const AutoClickerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Auto Clicker Minimalis',
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
      home: const ConfigScreen(),
    );
  }
}

class ConfigScreen extends StatefulWidget {
  const ConfigScreen({super.key});

  @override
  State<ConfigScreen> createState() => _ConfigScreenState();
}

class _ConfigScreenState extends State<ConfigScreen> {
  final _labelCtrl = TextEditingController(text: 'Tombol Target');
  final _xCtrl = TextEditingController(text: '540');
  final _yCtrl = TextEditingController(text: '1200');
  final _delayCtrl = TextEditingController(text: '200');

  StreamSubscription<EngineEvent>? _sub;
  bool _running = false;
  int _clickCount = 0;

  @override
  void dispose() {
    _sub?.cancel();      // berhenti mendengarkan -> engine Rust ikut berhenti
    stopAutoClick();
    for (final c in [_labelCtrl, _xCtrl, _yCtrl, _delayCtrl]) {
      c.dispose();
    }
    super.dispose();
  }

  void _showMessage(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _toggle() async {
    // --- Hentikan ---
    if (_running) {
      stopAutoClick(); // UI diperbarui oleh event Stopped
      return;
    }

    // --- Validasi input ---
    final x = int.tryParse(_xCtrl.text);
    final y = int.tryParse(_yCtrl.text);
    final delay = int.tryParse(_delayCtrl.text);
    if (x == null || y == null || delay == null) {
      _showMessage('Koordinat dan delay harus berupa angka.');
      return;
    }

    // --- Android: pastikan Accessibility Service aktif ---
    if (Platform.isAndroid && !await AndroidClicker.isServiceEnabled()) {
      await AndroidClicker.openSettings();
      _showMessage('Aktifkan layanan "Auto Clicker" di Aksesibilitas, lalu kembali.');
      return;
    }
    if (!mounted) return;

    final config = ClickConfig(
      label: _labelCtrl.text.trim(),
      x: x,
      y: y,
      intervalMs: delay,
    );

    setState(() {
      _running = true;
      _clickCount = 0;
    });

    _sub = startAutoClick(config: config).listen(
      _onEvent,
      onError: (Object error) {
        _showMessage('Gagal memulai: $error');
        if (mounted) setState(() => _running = false);
      },
      onDone: () {
        if (mounted) setState(() => _running = false);
      },
    );
  }

  void _onEvent(EngineEvent event) {
    switch (event) {
      case EngineEvent_Click(:final x, :final y):
        if (Platform.isAndroid) {
          // Rust yang mengatur ritme; Kotlin yang mengetuk layar.
          unawaited(AndroidClicker.tap(x, y).catchError((_) => false));
        }
        setState(() => _clickCount++);
      case EngineEvent_Failed(:final message):
        _showMessage(message);
        setState(() => _running = false);
      case EngineEvent_Stopped():
        setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Auto Clicker Minimalis')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _labelCtrl,
            enabled: !_running,
            decoration: const InputDecoration(
              labelText: 'Nama tombol target',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(child: _numberField(_xCtrl, 'X (px)')),
              const SizedBox(width: 12),
              Expanded(child: _numberField(_yCtrl, 'Y (px)')),
            ],
          ),
          const SizedBox(height: 12),
          _numberField(_delayCtrl, 'Delay antar klik (ms)'),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: _toggle,
            icon: Icon(_running ? Icons.stop : Icons.play_arrow),
            label: Text(_running ? 'Hentikan' : 'Mulai Otomasi'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          ),
          const SizedBox(height: 16),
          Center(
            child: Text(
              _running ? 'Berjalan... klik terkirim: $_clickCount' : 'Siap.',
              style: Theme.of(context).textTheme.bodyLarge,
            ),
          ),
        ],
      ),
    );
  }

  Widget _numberField(TextEditingController controller, String label) {
    return TextField(
      controller: controller,
      enabled: !_running,
      keyboardType: TextInputType.number,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
      ),
    );
  }
}
```

**Cara mengujinya:**

1. **Desktop dulu** (paling mudah): `flutter run -d windows` (atau macos/linux). Ubah X dan Y sesuai ukuran layarmu, lalu arahkan kursor ke area aman (mis. jendela editor teks kosong). Tekan **Mulai Otomasi** dan lihat kursor bergerak/klik. Tekan **Hentikan**.
2. **Android:** `flutter run`. Saat pertama menekan Mulai, kamu diarahkan ke Pengaturan Aksesibilitas. Aktifkan layanannya, kembali ke app, tekan Mulai lagi. Tekan tombol Home: tap tetap berjalan selama proses aplikasi hidup.

> Koordinat `(x, y)` adalah **piksel layar**, bukan piksel logis Flutter. Di desktop dengan DPI scaling (mis. 150%), hasilnya bisa bergeser sesuai faktor skala.

### 4.3 Berjalan di Background & Overlay (Gambaran Realistis)

Dengan kode di atas, otomasi berjalan selama **proses aplikasi** hidup, termasuk saat kamu menekan Home. Tetapi Android bisa mematikan proses di background (hemat baterai/memori). Untuk membuatnya andal:

| Kebutuhan | Pendekatan |
|-----------|------------|
| Tetap hidup di background | **Foreground Service** dengan notifikasi permanen. Di Flutter bisa memakai paket seperti `flutter_foreground_task`. Matikan juga optimasi baterai untuk aplikasi ini. |
| Tombol Start/Stop mengambang | **Overlay** dengan `SYSTEM_ALERT_WINDOW` (paket seperti `flutter_overlay_window`). Overlay berjalan di entry point Dart terpisah dan berkomunikasi lewat message passing. Ini topik lanjutan. |
| Klik sangat cepat (< 100 ms) | Gesture Android berdurasi tertentu (di kode kita 50 ms). Gunakan interval ≥ 100 ms agar tap tidak saling tumpang tindih. |

Ingat: karena di Android Rust mengirim event lewat Dart, **isolate Dart harus tetap hidup**. Ini alasan lain kenapa foreground service direkomendasikan untuk pemakaian serius.

---

### 4.4 Tugas Praktik (Ganti Baris Kode)

Cuplikan awal bagian `_toggle()`:

```dart
Future<void> _toggle() async {
  // ... (cabang berhenti dihilangkan)
  final x = int.parse(_xCtrl.text);
  final y = int.parse(_yCtrl.text);
  final delay = int.parse(_delayCtrl.text);

  final config = ClickConfig(label: _labelCtrl.text.trim(), x: x, y: y, intervalMs: delay);

  setState(() => _running = true);
  _sub = startAutoClick(config: config).listen(_onEvent);
}
```

1. Ganti baris `final x = int.parse(_xCtrl.text);` menjadi `final x = int.tryParse(_xCtrl.text);` (lakukan hal sama untuk `y` dan `delay`, lalu tambahkan pengecekan `if (x == null || y == null || delay == null) { return; }` sebelum membuat `config`) agar aplikasi tidak crash dengan `FormatException` ketika pengguna mengosongkan atau salah mengetik kolom angka.
2. Ganti baris `_sub = startAutoClick(config: config).listen(_onEvent);` menjadi `_sub = startAutoClick(config: config).listen(_onEvent, onDone: () { if (mounted) setState(() => _running = false); });` agar tombol kembali menjadi "Mulai Otomasi" ketika stream ditutup dari sisi Rust (misalnya engine selesai sendiri).

<details>
<summary>Lihat Solusi & Penjelasan</summary>

```dart
Future<void> _toggle() async {
  final x = int.tryParse(_xCtrl.text);
  final y = int.tryParse(_yCtrl.text);
  final delay = int.tryParse(_delayCtrl.text);
  if (x == null || y == null || delay == null) {
    _showMessage('Koordinat dan delay harus berupa angka.');
    return;
  }

  final config = ClickConfig(label: _labelCtrl.text.trim(), x: x, y: y, intervalMs: delay);

  setState(() => _running = true);
  _sub = startAutoClick(config: config).listen(
    _onEvent,
    onDone: () {
      if (mounted) setState(() => _running = false);
    },
  );
}
```

**Pembahasan 1:** `int.parse` melempar `FormatException` jika teks bukan angka valid (mis. kosong). `int.tryParse` mengembalikan `null` sebagai gantinya, sehingga kita bisa menampilkan pesan ramah. Setelah pengecekan `null`, Dart melakukan *type promotion* sehingga `x`, `y`, `delay` diperlakukan sebagai `int` non-null.

**Pembahasan 2:** Stream dari Rust bisa selesai tanpa pengguna menekan tombol, misalnya karena `max_clicks` tercapai atau terjadi error. Tanpa `onDone`, variabel `_running` bisa tetap `true` sehingga UI menampilkan "Hentikan" padahal engine sudah mati. `mounted` dicek agar tidak memanggil `setState` pada widget yang sudah dibuang.

</details>

---

### 4.5 Tantangan "Fix the Syntax" (Debug Challenge)

```dart
void _onTogglePressed() {
  if (Platform.isAndroid) {
    final aktif = await AndroidClicker.isServiceEnabled();
    if (!aktif) {
      AndroidClicker.openSettings();
      return;
    }
  }
  _mulaiEngine();
}
```

**Simulasi pesan error `dart analyze`:**

```text
error • lib/main.dart:3:19 • The 'await' expression can only be used in an
        'async' function. Try marking the function body with either 'async'
        or 'async*'. • await_in_wrong_context
```

<details>
<summary>Perbaikan Sintaks & Pembahasan</summary>

```dart
Future<void> _onTogglePressed() async {
  if (Platform.isAndroid) {
    final aktif = await AndroidClicker.isServiceEnabled();
    if (!aktif) {
      await AndroidClicker.openSettings();
      return;
    }
  }
  if (!mounted) return; // widget bisa saja sudah dibuang selama menunggu
  _mulaiEngine();
}
```

**Penyebab:** `await` hanya boleh dipakai di dalam fungsi bertanda `async`. Fungsi aslinya bertipe `void` biasa, sehingga Dart menolak. Pola yang sama berlaku di Rust (`.await` hanya di `async fn`).

**Catatan tambahan:**

- Fungsi `async` mengembalikan `Future<void>`. Parameter `onPressed` pada tombol Flutter tetap menerimanya.
- Setelah `await`, widget mungkin sudah tidak ada di layar. Jika kamu memakai `setState` atau `BuildContext` sesudahnya, cek `mounted` dulu.
- `openSettings()` sebaiknya di-`await` agar urutan eksekusinya jelas dan error dari platform channel bisa ditangkap.

</details>

---

## Penutup: Langkah Lanjutan & Troubleshooting

### Ide pengembangan berikutnya

1. **Foreground service + overlay** agar benar-benar berjalan "tanpa UI" (lihat Bagian 4.3).
2. **Pemilih koordinat visual:** overlay transparan di layar; sentuh posisi target, koordinat tersimpan otomatis. Lebih nyaman daripada mengetik angka.
3. **Deteksi layar:** ambil tangkapan layar (Android `MediaProjection`), lalu lakukan *template matching* di Rust (crate seperti `image` atau binding OpenCV) untuk menemukan tombol target secara otomatis.
4. **Daftar target & urutan klik** (beberapa titik bergantian, jeda acak kecil).
5. **Simpan konfigurasi** (`shared_preferences` di Dart atau file JSON via `serde` di Rust).
6. **Pengujian engine** dengan `Injector` palsu (trait) supaya loop bisa dites tanpa mengklik layar sungguhan.

### Troubleshooting cepat

| Gejala | Kemungkinan penyebab | Solusi |
|--------|----------------------|--------|
| `Bad state: flutter_rust_bridge has not been initialized` / error serupa saat memanggil fungsi Rust | Lupa `await RustLib.init()` | Pastikan ada di `main()` yang `async`, sebelum `runApp` |
| Fungsi Rust baru tidak muncul di Dart | Fungsi tidak `pub`, tidak di folder `api/`, atau belum generate | Tambah `pub`, pindah ke `rust/src/api/`, jalankan `flutter_rust_bridge_codegen generate` |
| Error build Rust untuk Android terkait `enigo` | `enigo` tidak dibatasi `cfg` | Pakai blok `[target.'cfg(any(target_os = "windows", target_os = "macos", target_os = "linux"))'.dependencies]` |
| Android: tap tidak terjadi, `NO_SERVICE` | Accessibility Service belum aktif | Aktifkan di Pengaturan → Aksesibilitas (cek "Restricted setting" di Android 13+) |
| Android: `tap` mengembalikan `false` | `canPerformGestures` belum `true`, atau koordinat di luar layar | Periksa file XML konfigurasi dan nilai `(x, y)` |
| macOS: klik tidak terjadi | Belum ada izin Accessibility | System Settings → Privacy & Security → Accessibility |
| Linux: klik tidak terjadi | Sesi Wayland | Uji di sesi X11 |
| UI membeku saat start | Ada loop/`sleep` di fungsi `#[frb(sync)]` | Pindahkan ke thread terpisah (`spawn_click_loop`), jangan sync |
| Tombol Hentikan terasa lambat | `sleep` panjang tanpa cek flag | Gunakan `sleep_until` yang memotong tidur ≤ 50 ms |
| `E0373 closure may outlive...` | Closure di `thread::spawn` tanpa `move` | Tambah `move`, `clone()` `Arc` sebelum dipindahkan |
| `argument_type_not_assignable ... BigInt` | Field Rust bertipe `u64` | Ubah ke `u32` atau kirim `BigInt.from(...)` |

### Tips membaca error Rust & Dart saat membangun proyek ini

1. Selesaikan **error pertama** dulu. Error lain sering hanya efek berantai.
2. Error `E0373`, `E0382`, `E0499` hampir selalu soal ownership/thread. Baca bagian `help:` dari `rustc`.
3. Jalankan `cargo check` di folder `rust/` untuk umpan balik cepat tanpa membangun seluruh aplikasi Flutter.
4. Jalankan `dart analyze` (atau lihat panel Problems di IDE) untuk error sisi Dart.
5. Setiap mengubah `rust/src/api/*.rs`, **generate ulang** jembatannya sebelum menjalankan aplikasi.

### Sumber belajar

- Dokumentasi flutter_rust_bridge: <https://cjycode.com/flutter_rust_bridge/>
- `enigo` di docs.rs: <https://docs.rs/enigo>
- Android AccessibilityService & gesture: <https://developer.android.com/reference/android/accessibilityservice/AccessibilityService>
- Panduan Dart FFI: <https://dart.dev/interop/c-interop>
- The Rust Book (ownership, thread, `Arc`/`Mutex`): <https://doc.rust-lang.org/book/>

---

*Selamat membangun! Ingat prinsip arsitektur proyek ini: **Rust mengatur ritme, Flutter mengatur tampilan, OS yang memberi izin.** Gunakan dengan bertanggung jawab.* 🦀
