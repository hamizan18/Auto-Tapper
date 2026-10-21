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
                  onChanged: active
                      ? null
                      : (v) => setState(() => _interval = v),
                ),
                _numberField(
                  _loopCtrl,
                  'Jumlah loop (0 = tanpa batas)',
                  active,
                ),
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
                    onPressed: _controller.isPaused
                        ? _controller.resume
                        : _controller.pause,
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
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
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
