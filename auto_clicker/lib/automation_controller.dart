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
          _message =
              'Layanan aksesibilitas belum aktif. Aktifkan dulu di Pengaturan.';
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
