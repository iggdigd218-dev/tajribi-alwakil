import 'dart:async';

import 'package:flutter/material.dart';

import '../models/agent_action_intent.dart';
import '../services/agent_dispatcher.dart';
import '../services/automation_service.dart';
import '../services/gemini_service.dart';
import '../services/intent_parser_service.dart';
import '../services/scheduler_service.dart';
import '../services/system_bridge_service.dart';
import '../services/overlay_service.dart';
import '../services/voice_service.dart';

/// شاشة الدردشة مع وكيل الأتمتة.
class AgentChatScreen extends StatefulWidget {
  const AgentChatScreen({super.key});

  @override
  State<AgentChatScreen> createState() => _AgentChatScreenState();
}

class _ChatEntry {
  _ChatEntry.user(this.text)
      : isUser = true,
        result = null;
  _ChatEntry.agent({this.text, this.result}) : isUser = false;

  final bool isUser;
  final String? text;
  final AgentDispatchResult? result;
  AgentActionIntent? pendingIntent;
}

class _AgentChatScreenState extends State<AgentChatScreen> {
  final TextEditingController _inputController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final List<_ChatEntry> _entries = <_ChatEntry>[];

  Timer? _statusTimer;
  bool _accessibilityOn = false;
  bool _shizukuRunning = false;
  bool _shizukuGranted = false;
  bool _foregroundActive = false;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _entries.add(
      _ChatEntry.agent(
        text: 'مرحباً 👋 أنا وكيل الأتمتة الخاص بك.\n'
            'جرّب أوامر مثل:\n'
            '• "شغل الواي فاي" / "اطفئ البيانات"\n'
            '• "اتصل بـ 712345678 من الشريحة 2"\n'
            '• "بعد 10 دقائق اطفئ البيانات"\n'
            '• "افتح واتساب" / "افتح محفظة جوادي"',
      ),
    );
    VoiceService.init();
    VoiceService.onVoiceCommandExecuted = _onVoiceCommandExecuted;
    VoiceService.onAssistantReply = _onAssistantReply;
    GeminiService.loadSavedKey();

    _refreshStatus();
    _statusTimer = Timer.periodic(
      const Duration(seconds: 3),
      (_) => _refreshStatus(),
    );
  }

  @override
  void dispose() {
    _statusTimer?.cancel();
    _inputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _refreshStatus() async {
    final accessibility = await AutomationService.isServiceRunning();
    final shizuku = await SystemBridgeService.checkShizukuPermission();
    final foreground = await SchedulerService.isForegroundServiceRunning();
    if (!mounted) return;
    setState(() {
      _accessibilityOn = accessibility;
      _shizukuRunning = shizuku.shizukuRunning;
      _shizukuGranted = shizuku.permissionGranted;
      _foregroundActive = foreground;
    });
  }

  Future<void> _handleSend() async {
    final text = _inputController.text.trim();
    if (text.isEmpty || _sending) return;
    _inputController.clear();

    setState(() {
      _entries.add(_ChatEntry.user(text));
      _sending = true;
    });
    _scrollToBottom();

    try {
      await GeminiService.loadSavedKey();

      final intent = IntentParserService.parseLocal(text);
      if (intent != null) {
        await _dispatchIntent(intent);
        return;
      }

      if (!GeminiService.isConfigured) {
        if (!mounted) return;
        setState(() {
          _entries.add(
            _ChatEntry.agent(
              text: 'هذا نص حواري ويحتاج محرك الذكاء الاصطناعي.\n'
                  'اضبط المزود والمفتاح من الإعدادات ⚙️ ثم أعد المحاولة.',
            ),
          );
        });
        return;
      }

      final outcome = await GeminiService.processVoiceCommand(text);
      if (!mounted) return;

      if (outcome.hasError &&
          outcome.reply.isEmpty &&
          outcome.actions.isEmpty) {
        setState(() {
          _entries.add(
            _ChatEntry.agent(
              text: '⚠️ تعذر الاتصال بالمحرك السحابي.\n'
                  '${outcome.error ?? "خطأ غير معروف — تحقق من المفتاح أو الاتصال."}',
            ),
          );
        });
        return;
      }

      if (outcome.reply.isNotEmpty) {
        setState(() => _entries.add(_ChatEntry.agent(text: outcome.reply)));
        await VoiceService.speak(outcome.reply);
      }

      for (final actionIntent in outcome.actions) {
        await _dispatchIntent(actionIntent);
      }

      if (outcome.reply.isEmpty && outcome.actions.isEmpty) {
        setState(() {
          _entries.add(
            _ChatEntry.agent(
              text: outcome.hasError
                  ? '⚠️ ${outcome.error}'
                  : 'لم يصل رد من المحرك السحابي. حاول صياغة أوضح.',
            ),
          );
        });
      }
    } finally {
      if (mounted) {
        setState(() => _sending = false);
        _scrollToBottom();
      }
    }
  }

  Future<void> _dispatchIntent(AgentActionIntent intent) async {
    final result = await AgentDispatcher.execute(intent);
    final entry = _ChatEntry.agent(result: result);
    if (result.status == AgentDispatchStatus.needsConfirmation) {
      entry.pendingIntent = intent;
    }
    setState(() => _entries.add(entry));
    _scrollToBottom();
  }

  Future<void> _confirmExecution(AgentActionIntent intent) async {
    setState(() {
      for (final entry in _entries) {
        if (entry.pendingIntent?.id == intent.id) {
          entry.pendingIntent = null;
        }
      }
    });
    final result = await AgentDispatcher.execute(intent, confirmed: true);
    setState(() => _entries.add(_ChatEntry.agent(result: result)));
    _scrollToBottom();
  }

  void _cancelExecution(AgentActionIntent intent) {
    setState(() {
      for (final entry in _entries) {
        if (entry.pendingIntent?.id == intent.id) {
          entry.pendingIntent = null;
        }
      }
      _entries.add(_ChatEntry.agent(text: 'تم إلغاء العملية بنجاح ✖'));
    });
    _scrollToBottom();
  }

  void _onVoiceCommandExecuted(
    String command,
    AgentActionIntent intent,
    AgentDispatchResult result,
  ) {
    setState(() {
      _entries.add(_ChatEntry.user('🎙️ $command'));
      final entry = _ChatEntry.agent(result: result);
      if (result.status == AgentDispatchStatus.needsConfirmation) {
        entry.pendingIntent = intent;
      }
      _entries.add(entry);
    });
    _scrollToBottom();
  }

  void _onAssistantReply(String reply) {
    setState(() => _entries.add(_ChatEntry.agent(text: '🗣️ $reply')));
    _scrollToBottom();
  }

  Future<void> _toggleListening() async {
    if (VoiceService.isListening.value) {
      await VoiceService.stopListening();
      _showSnack('تم إيقاف الاستماع الصوتي');
    } else {
      final ok = await VoiceService.startListening();
      if (!ok) {
        _showSnack('تعذر بدء الاستماع — تأكد من منح صلاحية الميكروفون');
      }
    }
  }

  InputDecoration _fieldDecoration({required String hint, Widget? suffix}) {
    return InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(color: Color(0xFF5A7A96)),
      isDense: true,
      filled: true,
      fillColor: const Color(0xFF0E1621),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: Color(0xFF3A5068)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: Color(0xFF0E7C86)),
      ),
      suffixIcon: suffix,
    );
  }

  Future<void> _showSettingsDialog() async {
    await GeminiService.loadSavedKey();
    var selectedId = GeminiService.providerId;
    final keyController = TextEditingController(text: GeminiService.apiKey);
    final modelController = TextEditingController(text: GeminiService.model);
    final endpointController =
        TextEditingController(text: GeminiService.endpoint);
    final wakeController =
        TextEditingController(text: VoiceService.wakeWord.value);
    var keyConfigured = GeminiService.isConfigured;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          backgroundColor: const Color(0xFF16222F),
          title: const Text(
            'الإعدادات',
            style: TextStyle(color: Colors.white, fontSize: 17),
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'مزود الذكاء الاصطناعي',
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 6),
                DropdownButtonFormField<String>(
                  value: selectedId,
                  dropdownColor: const Color(0xFF16222F),
                  isExpanded: true,
                  decoration: _fieldDecoration(hint: 'اختر المزود'),
                  items: [
                    for (final p in GeminiService.providers)
                      DropdownMenuItem(
                        value: p.id,
                        child: Text(
                          p.label,
                          style:
                              const TextStyle(color: Colors.white, fontSize: 13),
                        ),
                      ),
                  ],
                  onChanged: (id) {
                    if (id == null) return;
                    final p = GeminiService.byId(id);
                    setDialogState(() {
                      selectedId = id;
                      if (p.id != 'custom') {
                        modelController.text = p.defaultModel;
                        endpointController.text = p.endpoint;
                      }
                    });
                  },
                ),
                const SizedBox(height: 10),
                const Text(
                  'الموديل',
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 6),
                TextField(
                  controller: modelController,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                  decoration: _fieldDecoration(hint: 'اسم الموديل'),
                ),
                if (selectedId == 'custom') ...[
                  const SizedBox(height: 10),
                  const Text(
                    'Endpoint',
                    style: TextStyle(
                      color: Colors.white70,
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 6),
                  TextField(
                    controller: endpointController,
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                    decoration: _fieldDecoration(
                      hint: 'https://.../v1/chat/completions',
                    ),
                  ),
                ],
                const SizedBox(height: 10),
                const Text(
                  'مفتاح API',
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 6),
                TextField(
                  controller: keyController,
                  obscureText: true,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                  decoration: _fieldDecoration(
                    hint: 'sk-... أو gsk_...',
                    suffix: IconButton(
                      icon: const Icon(
                        Icons.save_outlined,
                        color: Color(0xFF0E7C86),
                        size: 18,
                      ),
                      tooltip: 'حفظ إعدادات الذكاء',
                      onPressed: () async {
                        final info = GeminiService.byId(selectedId);
                        final ok = await GeminiService.saveSettings(
                          provider: selectedId,
                          endpoint: selectedId == 'custom'
                              ? endpointController.text
                              : info.endpoint,
                          model: modelController.text,
                          apiKey: keyController.text,
                        );
                        setDialogState(
                          () => keyConfigured = GeminiService.isConfigured,
                        );
                        _showSnack(
                          ok
                              ? 'تم حفظ ${info.label} بنجاح 🔐'
                              : 'فشل الحفظ — أدخل المفتاح',
                        );
                      },
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  keyConfigured
                      ? '✓ ${GeminiService.providerLabel} جاهز — ${GeminiService.model}'
                      : '✗ لا مفتاح — الأوامر المحلية فقط',
                  style: TextStyle(
                    fontSize: 11,
                    color: keyConfigured
                        ? const Color(0xFF35C77B)
                        : const Color(0xFFE05B4C),
                  ),
                ),
                const Divider(color: Color(0xFF22344A), height: 28),
                const Text(
                  'اسم الوكيل (كلمة النداء)',
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 6),
                TextField(
                  controller: wakeController,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                  decoration: _fieldDecoration(
                    hint: 'مثال: يا وكيل',
                    suffix: IconButton(
                      icon: const Icon(
                        Icons.save_outlined,
                        color: Color(0xFF0E7C86),
                        size: 18,
                      ),
                      tooltip: 'حفظ الاسم',
                      onPressed: () async {
                        final name = wakeController.text.trim();
                        if (name.isEmpty) return;
                        final ok = await VoiceService.setWakeWord(name);
                        _showSnack(
                          ok
                              ? 'تم حفظ اسم الوكيل: «$name» 🎙️'
                              : 'فشل حفظ الاسم',
                        );
                      },
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  'نادِ الوكيل بهذا الاسم ثم قل أمرك مباشرة.',
                  style: TextStyle(color: Colors.white38, fontSize: 11),
                ),
                const Divider(color: Color(0xFF22344A), height: 28),
                ValueListenableBuilder<bool>(
                  valueListenable: VoiceService.isListening,
                  builder: (context, listeningValue, _) => SwitchListTile(
                    value: listeningValue,
                    onChanged: (value) async {
                      if (value) {
                        final ok = await VoiceService.startListening();
                        if (!ok) {
                          _showSnack(
                              'تعذر بدء الاستماع — تأكد من صلاحية الميكروفون');
                          return;
                        }
                      } else {
                        await VoiceService.stopListening();
                      }
                    },
                    activeColor: const Color(0xFF35C77B),
                    title: const Text(
                      'الاستماع الدائم',
                      style: TextStyle(color: Colors.white, fontSize: 14),
                    ),
                    subtitle: const Text(
                      'يعمل والشاشة مغلقة (يستهلك البطارية)',
                      style: TextStyle(color: Colors.white38, fontSize: 11),
                    ),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
                const Divider(color: Color(0xFF22344A), height: 28),
                FutureBuilder<bool>(
                  future: OverlayService.hasOverlayPermission(),
                  builder: (context, snap) {
                    final granted = snap.data ?? false;
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'النافذة العائمة',
                          style: TextStyle(
                            color: Colors.white70,
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          granted
                              ? '✓ صلاحية العرض فوق التطبيقات ممنوحة'
                              : '✗ يلزم منح صلاحية «العرض فوق التطبيقات»',
                          style: TextStyle(
                            fontSize: 11,
                            color: granted
                                ? const Color(0xFF35C77B)
                                : const Color(0xFFE05B4C),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton(
                                onPressed: () async {
                                  await OverlayService
                                      .requestOverlayPermission();
                                  _showSnack(
                                      'فعّل «السماح بالعرض فوق التطبيقات» ثم ارجع');
                                },
                                child: const Text('منح الصلاحية'),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: FilledButton(
                                onPressed: () async {
                                  if (!granted) {
                                    await OverlayService
                                        .requestOverlayPermission();
                                    return;
                                  }
                                  final showing =
                                      await OverlayService.isOverlayShowing();
                                  if (showing) {
                                    await OverlayService.hideOverlay();
                                    _showSnack('تم إخفاء النافذة العائمة');
                                  } else {
                                    final ok =
                                        await OverlayService.showOverlay();
                                    _showSnack(
                                      ok
                                          ? 'النوافذ العائمة ظاهرة'
                                          : 'تعذر إظهار النافذة العائمة',
                                    );
                                  }
                                },
                                child: const Text('إظهار / إخفاء'),
                              ),
                            ),
                          ],
                        ),
                      ],
                    );
                  },
                ),
                const Divider(color: Color(0xFF22344A), height: 28),
                FutureBuilder<bool>(
                  future: OverlayService.isDefaultAssistant(),
                  builder: (context, snap) {
                    final isDefault = snap.data ?? false;
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'المساعد الافتراضي',
                          style: TextStyle(
                            color: Colors.white70,
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          isDefault
                              ? '✓ هذا التطبيق هو المساعد الرقمي الافتراضي'
                              : 'اجعله المساعد الافتراضي لاستدعائه من زر المنزل',
                          style: TextStyle(
                            fontSize: 11,
                            color: isDefault
                                ? const Color(0xFF35C77B)
                                : const Color(0xFF9AAABD),
                          ),
                        ),
                        const SizedBox(height: 8),
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            onPressed: () async {
                              await OverlayService.openAssistantSettings();
                              _showSnack(
                                  'اختر «وكيل الأتمتة» كتطبيق المساعد الرقمي');
                            },
                            icon: const Icon(Icons.record_voice_over, size: 16),
                            label: const Text('فتح إعدادات المساعد'),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('إغلاق'),
            ),
          ],
        ),
      ),
    );

    keyController.dispose();
    modelController.dispose();
    endpointController.dispose();
    wakeController.dispose();
  }

  Widget _buildListeningBanner() {
    return ValueListenableBuilder<bool>(
      valueListenable: VoiceService.isListening,
      builder: (context, listening, _) {
        if (!listening) return const SizedBox.shrink();
        return ValueListenableBuilder<String>(
          valueListenable: VoiceService.wakeWord,
          builder: (context, name, _) {
            return Container(
              margin: const EdgeInsets.fromLTRB(12, 4, 12, 0),
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0xFF122428),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFF2E5C4A)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.graphic_eq,
                      color: Color(0xFF35C77B), size: 16),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'الاستماع نشط — نادِني بـ «$name» ثم قل أمرك',
                      style: const TextStyle(
                          color: Color(0xFF9FD8BC), fontSize: 12),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _onAccessibilityChipTap() async {
    await AutomationService.openAccessibilitySettings();
  }

  Future<void> _onShizukuChipTap() async {
    if (!_shizukuRunning) {
      _showSnack('شغّل تطبيق Shizuku على الجهاز أولاً ثم أعد المحاولة');
      return;
    }
    final granted = await SystemBridgeService.requestShizukuPermission();
    _showSnack(granted ? 'تم منح صلاحية Shizuku ✅' : 'لم تُمنح الصلاحية');
    _refreshStatus();
  }

  Future<void> _onForegroundChipTap() async {
    if (_foregroundActive) {
      await SchedulerService.stopForegroundService();
    } else {
      await SchedulerService.startForegroundService();
    }
    _refreshStatus();
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: const Color(0xFF0E1621),
        body: SafeArea(
          child: Column(
            children: [
              _buildHeader(),
              _ServicesStatusStrip(
                accessibilityOn: _accessibilityOn,
                shizukuRunning: _shizukuRunning,
                shizukuGranted: _shizukuGranted,
                foregroundActive: _foregroundActive,
                onAccessibilityTap: _onAccessibilityChipTap,
                onShizukuTap: _onShizukuChipTap,
                onForegroundTap: _onForegroundChipTap,
              ),
              _buildListeningBanner(),
              Expanded(child: _buildMessagesList()),
              _buildInputRow(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Row(
        children: [
          const CircleAvatar(
            radius: 16,
            backgroundColor: Color(0xFF0E7C86),
            child: Text('🤖', style: TextStyle(fontSize: 16)),
          ),
          const SizedBox(width: 10),
          const Text(
            'وكيل الأتمتة',
            style: TextStyle(
              color: Colors.white,
              fontSize: 17,
              fontWeight: FontWeight.bold,
            ),
          ),
          const Spacer(),
          ValueListenableBuilder<bool>(
            valueListenable: VoiceService.isListening,
            builder: (context, listening, _) => IconButton(
              onPressed: _toggleListening,
              tooltip: listening ? 'إيقاف الاستماع' : 'بدء الاستماع الصوتي',
              icon: Icon(
                listening ? Icons.mic : Icons.mic_none,
                color: listening
                    ? const Color(0xFF35C77B)
                    : const Color(0xFF5A7A96),
                size: 22,
              ),
            ),
          ),
          IconButton(
            onPressed: _showSettingsDialog,
            tooltip: 'الإعدادات',
            icon: const Icon(
              Icons.settings_outlined,
              color: Color(0xFF5A7A96),
              size: 22,
            ),
          ),
          const Icon(Icons.smart_toy_outlined,
              color: Color(0xFF5A7A96), size: 22),
        ],
      ),
    );
  }

  Widget _buildMessagesList() {
    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      itemCount: _entries.length,
      itemBuilder: (context, index) {
        final entry = _entries[index];
        return entry.isUser
            ? _UserBubble(text: entry.text ?? '')
            : _AgentMessage(
                entry: entry,
                onConfirm: entry.pendingIntent != null
                    ? () => _confirmExecution(entry.pendingIntent!)
                    : null,
                onCancel: entry.pendingIntent != null
                    ? () => _cancelExecution(entry.pendingIntent!)
                    : null,
              );
      },
    );
  }

  Widget _buildInputRow() {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      decoration: const BoxDecoration(
        color: Color(0xFF16222F),
        border: Border(top: BorderSide(color: Color(0xFF22344A))),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _inputController,
              enabled: !_sending,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _handleSend(),
              style: const TextStyle(color: Colors.white, fontSize: 15),
              decoration: InputDecoration(
                hintText: 'اكتب أمراً مثل: شغل الواي فاي...',
                hintStyle: const TextStyle(color: Color(0xFF5A7A96)),
                filled: true,
                fillColor: Color(0xFF0E1621),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton.filled(
            onPressed: _sending ? null : _handleSend,
            style: IconButton.styleFrom(
              backgroundColor: const Color(0xFF0E7C86),
              disabledBackgroundColor: const Color(0xFF2A4050),
            ),
            icon: _sending
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.send, color: Colors.white, size: 20),
          ),
        ],
      ),
    );
  }
}

class _ServicesStatusStrip extends StatelessWidget {
  const _ServicesStatusStrip({
    required this.accessibilityOn,
    required this.shizukuRunning,
    required this.shizukuGranted,
    required this.foregroundActive,
    required this.onAccessibilityTap,
    required this.onShizukuTap,
    required this.onForegroundTap,
  });

  final bool accessibilityOn;
  final bool shizukuRunning;
  final bool shizukuGranted;
  final bool foregroundActive;
  final VoidCallback onAccessibilityTap;
  final VoidCallback onShizukuTap;
  final VoidCallback onForegroundTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF16222F),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Expanded(
            child: _StatusChip(
              label: 'الإمكانية',
              active: accessibilityOn,
              activeText: 'On',
              inactiveText: 'Off',
              onTap: onAccessibilityTap,
            ),
          ),
          Expanded(
            child: _StatusChip(
              label: 'Shizuku',
              active: shizukuGranted,
              activeText: 'Granted',
              inactiveText: shizukuRunning ? 'Denied' : 'Not Running',
              inactiveColor: shizukuRunning ? Colors.orange : Colors.red,
              onTap: onShizukuTap,
            ),
          ),
          Expanded(
            child: _StatusChip(
              label: 'الخدمة',
              active: foregroundActive,
              activeText: 'Active',
              inactiveText: 'Stopped',
              inactiveColor: Colors.blueGrey,
              onTap: onForegroundTap,
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({
    required this.label,
    required this.active,
    required this.activeText,
    required this.inactiveText,
    required this.onTap,
    this.inactiveColor = Colors.red,
  });

  final String label;
  final bool active;
  final String activeText;
  final String inactiveText;
  final Color inactiveColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = active ? const Color(0xFF35C77B) : inactiveColor;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                ),
                const SizedBox(width: 5),
                Flexible(
                  child: Text(
                    label,
                    style: const TextStyle(color: Colors.white70, fontSize: 11),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              active ? activeText : inactiveText,
              style: TextStyle(
                color: color,
                fontSize: 11,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _UserBubble extends StatelessWidget {
  const _UserBubble({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.75,
        ),
        decoration: BoxDecoration(
          color: const Color(0xFF0E7C86),
          borderRadius: BorderRadius.circular(16).copyWith(
            bottomLeft: const Radius.circular(4),
          ),
        ),
        child: Text(
          text,
          style: const TextStyle(color: Colors.white, fontSize: 14.5, height: 1.4),
        ),
      ),
    );
  }
}

class _AgentMessage extends StatelessWidget {
  const _AgentMessage({
    required this.entry,
    this.onConfirm,
    this.onCancel,
  });

  final _ChatEntry entry;
  final VoidCallback? onConfirm;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.all(12),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.85,
        ),
        decoration: BoxDecoration(
          color: const Color(0xFF1C2733),
          borderRadius: BorderRadius.circular(16).copyWith(
            bottomRight: const Radius.circular(4),
          ),
        ),
        child: entry.text != null
            ? Text(
                entry.text!,
                style:
                    const TextStyle(color: Colors.white, fontSize: 14, height: 1.5),
              )
            : _AgentResultCard(
                entry: entry,
                onConfirm: onConfirm,
                onCancel: onCancel,
              ),
      ),
    );
  }
}

class _AgentResultCard extends StatelessWidget {
  const _AgentResultCard({
    required this.entry,
    this.onConfirm,
    this.onCancel,
  });

  final _ChatEntry entry;
  final VoidCallback? onConfirm;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final result = entry.result!;
    final pending = entry.pendingIntent;
    final showActions = pending != null && onConfirm != null && onCancel != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Text(_iconFor(result.status), style: const TextStyle(fontSize: 18)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _titleFor(result.status),
                style: TextStyle(
                  color: _colorFor(result.status),
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          result.message,
          style: const TextStyle(color: Colors.white70, fontSize: 13, height: 1.4),
        ),
        if (result.status == AgentDispatchStatus.scheduled &&
            result.intent.scheduledTime != null) ...[
          const SizedBox(height: 6),
          Text(
            '⏰ ${_formatDateTime(result.intent.scheduledTime!)}',
            style: const TextStyle(color: Color(0xFF5AB8F0), fontSize: 13),
          ),
        ],
        if (showActions) ...[
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: onConfirm,
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFFE05B4C),
                    padding: const EdgeInsets.symmetric(vertical: 8),
                  ),
                  icon: const Icon(Icons.check, size: 16),
                  label: const Text('تأكيد التنفيذ'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: onCancel,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white70,
                    side: const BorderSide(color: Color(0xFF3A5068)),
                    padding: const EdgeInsets.symmetric(vertical: 8),
                  ),
                  icon: const Icon(Icons.close, size: 16),
                  label: const Text('إلغاء'),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  static String _iconFor(AgentDispatchStatus status) {
    return switch (status) {
      AgentDispatchStatus.executed => '✅',
      AgentDispatchStatus.scheduled => '⏰',
      AgentDispatchStatus.needsConfirmation => '⚠️',
      AgentDispatchStatus.failed => '❌',
      AgentDispatchStatus.unknownCommand => '❓',
    };
  }

  static String _titleFor(AgentDispatchStatus status) {
    return switch (status) {
      AgentDispatchStatus.executed => 'تم تنفيذ الأمر بنجاح',
      AgentDispatchStatus.scheduled => 'تمت جدولة المهمة بنجاح',
      AgentDispatchStatus.needsConfirmation => 'مطلوب تأكيد عملية مالية',
      AgentDispatchStatus.failed => 'فشل التنفيذ',
      AgentDispatchStatus.unknownCommand => 'أمر غير معروف',
    };
  }

  static Color _colorFor(AgentDispatchStatus status) {
    return switch (status) {
      AgentDispatchStatus.executed => const Color(0xFF35C77B),
      AgentDispatchStatus.scheduled => const Color(0xFF5AB8F0),
      AgentDispatchStatus.needsConfirmation => const Color(0xFFF0A85A),
      AgentDispatchStatus.failed => const Color(0xFFE05B4C),
      AgentDispatchStatus.unknownCommand => const Color(0xFF9AAABD),
    };
  }
}

String _formatDateTime(DateTime time) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(time.hour)}:${two(time.minute)} — '
      '${time.day}/${time.month}/${time.year}';
}
