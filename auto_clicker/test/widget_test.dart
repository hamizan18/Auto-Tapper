import 'package:auto_clicker/main.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.example.auto_clicker/automation');

  setUp(() {
    // Tiruan sisi native: layanan aksesibilitas dianggap belum aktif.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'isServiceEnabled') return false;
      return null;
    });
  });

  testWidgets('Halaman utama tampil dengan banner izin', (tester) async {
    await tester.pumpWidget(const AutoClickerApp());
    await tester.pump();

    expect(find.text('Auto Clicker & Scroller'), findsOneWidget);
    expect(find.textContaining('belum aktif'), findsOneWidget);
  });
}
