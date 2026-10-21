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
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      home: const AutomationPage(),
    );
  }
}
