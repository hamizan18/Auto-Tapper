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
    this.loopCount = 0,
  });

  final ActionType actionType;
  final int x;
  final int y;
  final int scrollDistance;
  final int scrollDurationMs;
  final int intervalMs;
  final int loopCount;

  Map<String, dynamic> toMap() => {
    'actionType': actionType.name,
    'x': x,
    'y': y,
    'scrollDistance': scrollDistance,
    'scrollDurationMs': scrollDurationMs,
    'intervalMs': intervalMs,
    'loopCount': loopCount,
  };

  String? validate() {
    if (x < 0 || y < 0) return 'Koordinat tidak boleh negatif.';
    if (intervalMs < 100) return 'Interval minimal 100 ms.';
    if (loopCount < 0) return 'Jumlah loop tidak boleh negatif.';
    if (actionType == ActionType.scroll) {
      if (scrollDistance < 50) return 'Jarak scroll minimal 50 px.';
      if (scrollDurationMs < 100) return 'Durasi scroll minimal 100 ms/';
    }
    return null;
  }
}
