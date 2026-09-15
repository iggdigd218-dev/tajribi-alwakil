import 'package:flutter/material.dart';

import 'ui/agent_chat_screen.dart';

/// نقطة انطلاق وكيل الأتمتة — الشاشة الرئيسية هي شات الأوامر.
void main() {
  runApp(const AgentAutomationApp());
}

class AgentAutomationApp extends StatelessWidget {
  const AgentAutomationApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'وكيل الأتمتة',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0E1621),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF0E7C86),
          brightness: Brightness.dark,
        ),
      ),
      home: const AgentChatScreen(),
    );
  }
}
