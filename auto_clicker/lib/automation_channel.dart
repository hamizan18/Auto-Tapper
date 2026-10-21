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
  static const MethodChannel _channel = MethodChannel(
    'com.example.auto_clicker/automation',
  );

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

  Future<void> pauseAutomation() =>
      _channel.invokeMethod<void>('pauseAutomation');

  Future<void> resumeAutomation() =>
      _channel.invokeMethod<void>('resumeAutomation');

  Future<void> stopAutomation() =>
      _channel.invokeMethod<void>('stopAutomation');
}
