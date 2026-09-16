import 'package:flutter/services.dart' show Clipboard, ClipboardData;\nimport 'dart:async';

import 'package:flutter/material.dart';

import '../models/agent_action_intent.dart';
import '../services/agent_dispatcher.dart';
import '../services/automation_service.dart';
import '../services/gemini_service.dart';
import '../services/intent_parser_service.dart';
import '../services/offline_assistant.dart';
import '../services/scheduler_service.dart';
import '../services/system_bridge_service.dart';
import '../services/overlay_service.dart';
import '../services/voice_service.dart';
import '../services/voice_profiles.dart';

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
  _ChatEntry.agent({this.text, this.result, this.source}) : isUser = false;

  final bool isUser;
  String? text;
  final AgentDispatchResult? result;

  /// من الذي رد؟ (Groq / Gemini / وكيل الأتمتة / الوكيل المحلي)
  final String? source;
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
    // تشخيص الصوت: عند التراجع الاضطراري لمحرك النظام أظهر السبب
    VoiceService.onNeuralFallback = (reason) {
      if (!mounted) return;
      _showSnack('⚠ الصوت العصبي (AI) غير متاح الآن: $reason'
          ' — استُخدم محرك النظام');
    };
    GeminiService.loadSavedKey();

    _refreshStatus();
    _statusTimer = Timer.periodic(
      const Duration(seconds: 3),
      (_) => _refreshStatus(),
    );
  }

  @override
  void dispose() {
    VoiceService.onNeuralFallback = null;
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
    await _runPipeline(text);
  }

  /// مسارات معالجة طلب نصي مُضاف مسبقاً (إرسال جديد أو إعادة بعد تعديل).
  Future<void> _runPipeline(String text) async {
    try {
      await GeminiService.loadSavedKey();

      // ── المسار 1: المحلل المحلي + حلّ معرّف الحزمة من الجهاز ──
      // فوري ومجاني ويعمل دون إنترنت. إن فهم الأمر نفّذه مباشرة.
      var commandText = text;

      // ── المسار 1: الذكاء السحابي هو المستمع الأول لأي طلب (صوت أو نص) ──
      // يستقبل النص الخام، يصيغ الأمر الواضح، ووكيل الأتمتة ينفذه.
      GeminiVoiceOutcome? cloud;
      if (GeminiService.isConfigured) {
        cloud = await GeminiService.processVoiceCommand(
          text,
          history: _recentHistory(text),
        );
        if (!mounted) return;
        if (!cloud.hasError ||
            cloud.reply.isNotEmpty ||
            cloud.actions.isNotEmpty) {
          final reply = cloud.reply;
          final actions = cloud.actions;
          if (reply.isNotEmpty) {
            setState(() => _entries.add(_ChatEntry.agent(text: reply, source: GeminiService.providerLabel)));
            await VoiceService.speak(reply);
          }
          for (final actionIntent in actions) {
            await _dispatchIntent(actionIntent);
          }
          if (reply.isEmpty && actions.isEmpty) {
            setState(() => _entries.add(_ChatEntry.agent(
                  text: 'لم يصل رد من المحرك السحابي. حاول صياغة أوضح.')));
          }
          return;
        }
      }

      // ── المسار 2: المحلل المحلي الفوري + طبقة إعادة الصياغة ──
      var intent = await IntentParserService.parseLocalAsync(commandText);
      if (intent == null) {
        final reform = await GeminiService.reformulateCommand(text);
        if (reform != null && reform.trim().isNotEmpty) {
          commandText = reform.trim();
          intent = await IntentParserService.parseLocalAsync(commandText);
        }
      }
      if (intent != null) {
        await _dispatchIntent(intent);
        return;
      }

      // ── المسار 3: الدماغ المحلي (معرفة الجهاز + الحوار العام) ──
      final offline = await OfflineAssistant.respond(commandText);
      if (!mounted) return;
      if (offline.match != OfflineMatch.none) {
        setState(() => _entries.add(_ChatEntry.agent(text: offline.displayText, source: 'الوكيل المحلي')));
        if (offline.reply.isNotEmpty) await VoiceService.speak(offline.reply);
        for (final a in offline.actions) {
          await _dispatchIntent(a);
        }
        return;
      }

      // ── المسار 4: الموصل فشل أو غائب — رد محلي مفيد ──
      if (cloud != null) {
        final recovered = await OfflineAssistant.recoverFromConnectorFailure(
          text,
          cloud.error,
          statusCode: cloud.statusCode,
        );
        if (!mounted) return;
        setState(() {
          _entries.add(_ChatEntry.agent(text: recovered.displayText, source: 'الوكيل المحلي'));
        });
        for (final a in recovered.actions) {
          await _dispatchIntent(a);
        }
        return;
      }
      setState(() => _entries.add(_ChatEntry.agent(text: offline.displayText, source: 'الوكيل المحلي')));
      if (offline.reply.isNotEmpty) await VoiceService.speak(offline.reply);
    } finally {
      if (mounted) {
        setState(() => _sending = false);
        _scrollToBottom();
      }
    }
  }

  /// آخر 10 جولات حوارية (بدون الجولة الحالية) — ليناقش ويرجع للسياق
  /// مثل ChatGPT بدل أن يبدأ كل رسالة من الصفر.
  List<Map<String, Object?>> _recentHistory(String current) {
    final conv = _entries
        .where((e) => e.text != null && e.text!.trim().isNotEmpty)
        .toList();
    if (conv.isNotEmpty && conv.last.isUser && conv.last.text == current) {
      conv.removeLast();
    }
    final last = conv.length > 10 ? conv.sublist(conv.length - 10) : conv;
    return [
      for (final e in last)
        {'role': e.isUser ? 'user' : 'assistant', 'text': e.text!},
    ];
  }

  /// ضغط مطوّل على رسالة: نسخ / تعديل وإعادة إرسال / حذف.
  Future<void> _messageMenu(int index) async {
    final entry = _entries[index];
    final label = entry.text ?? entry.result?.message ?? '';
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF16222F),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.copy, color: Colors.white70),
              title: const Text('نسخ', style: TextStyle(color: Colors.white)),
              onTap: () {
                Navigator.pop(ctx);
                Clipboard.setData(ClipboardData(text: label));
                _showSnack('نُسخت الرسالة 📋');
              },
            ),
            if (entry.isUser)
              ListTile(
                leading: const Icon(Icons.edit_outlined, color: Colors.white70),
                title: const Text('تعديل وإعادة الإرسال',
                    style: TextStyle(color: Colors.white)),
                onTap: () {
                  Navigator.pop(ctx);
                  _editAndResend(index);
                },
              ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Color(0xFFE05B4C)),
              title: const Text('حذف', style: TextStyle(color: Colors.white)),
              onTap: () {
                Navigator.pop(ctx);
                setState(() => _entries.removeAt(index));
              },
            ),
          ],
        ),
      ),
    );
  }

  /// تعديل رسالة مستخدم ثم حذف ما بعدها وإعادة المعالجة من جديد.
  Future<void> _editAndResend(int index) async {
    final entry = _entries[index];
    final controller = TextEditingController(text: entry.text ?? '');
    final saved = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF131F2E),
        title: const Text('تعديل الرسالة',
            style: TextStyle(color: Colors.white, fontSize: 15)),
        content: TextField(
          controller: controller,
          maxLines: 3,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            hintText: 'نص الرسالة',
            hintStyle: TextStyle(color: Colors.white38),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('إلغاء'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('تعديل وإرسال'),
          ),
        ],
      ),
    );
    if (saved == null || saved.isEmpty || _sending) return;
    setState(() {
      entry.text = saved;
      if (index + 1 < _entries.length) {
        _entries.removeRange(index + 1, _entries.length);
      }
    });
    await _runPipeline(saved);
  }

  Future<void> _dispatchIntent(AgentActionIntent intent) async {
    final result = await AgentDispatcher.execute(intent);
    final entry = _ChatEntry.agent(result: result, source: 'وكيل الأتمتة');
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
    var voiceProfileId = VoiceService.voiceProfile.id;
    final keyController = TextEditingController(text: GeminiService.apiKey);
    final modelController = TextEditingController(text: GeminiService.model);
    final endpointController =
        TextEditingController(text: GeminiService.endpoint);
    final wakeController =
        TextEditingController(text: VoiceService.wakeWord.value);
    var keyConfigured = GeminiService.isConfigured;
    var testing = false;

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
                      ? GeminiService.isUsingBuiltInKey
                          ? '✓ ${GeminiService.providerLabel} جاهز (مفتاح مدمج) — ${GeminiService.model}'
                          : '✓ ${GeminiService.providerLabel} جاهز — ${GeminiService.model}'
                      : '✗ لا مفتاح — الأوامر المحلية تعمل على أي حال',
                  style: TextStyle(
                    fontSize: 11,
                    color: keyConfigured
                        ? const Color(0xFF35C77B)
                        : const Color(0xFFE05B4C),
                  ),
                ),
                const SizedBox(height: 12),

                // ═══ نبرة الصوت: خمسة أنماط رجالية ═══
                const Text(
                  'نبرة الصوت (صوت رجالي)',
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 6),
                for (final profile in VoiceProfile.all)
                  RadioListTile<String>(
                    value: profile.id,
                    groupValue: voiceProfileId,
                    secondary: IconButton(
                      tooltip: 'استمع لعينة',
                      icon: const Icon(
                        Icons.volume_up_outlined,
                        color: Color(0xFF7FD1DA),
                        size: 20,
                      ),
                      onPressed: () => VoiceService.speakSample(
                        'السلام عليكم. أنا صوت الوكيل بنمط ${profile.label}.',
                        profile,
                      ),
                    ),
                    activeColor: const Color(0xFF0E7C86),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      profile.label,
                      style: const TextStyle(color: Colors.white, fontSize: 13),
                    ),
                    subtitle: Text(
                      profile.description,
                      style: const TextStyle(color: Colors.white54, fontSize: 11),
                    ),
                    onChanged: (id) async {
                      if (id == null) return;
                      final ok = await VoiceService.setVoiceProfile(id);
                      if (!mounted) return;
                      setDialogState(() {
                        if (ok) voiceProfileId = id;
                      });
                      _showSnack(ok
                          ? 'اعتُمدت النبرة: ${VoiceProfile.byId(id).label} 🔊'
                          : 'تعذر حفظ النبرة');
                    },
                  ),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFF7FD1DA),
                    side: const BorderSide(color: Color(0xFF22344A)),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                  onPressed: () async {
                    final diag = await VoiceService.listeningDiagnostics();
                    if (!mounted) return;
                    showDialog<void>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        backgroundColor: const Color(0xFF131F2E),
                        title: const Text('تشخيص الاستماع بالخلفية',
                            style: TextStyle(color: Colors.white, fontSize: 15)),
                        content: Text(
                          diag,
                          style: const TextStyle(
                              color: Colors.white70, fontSize: 12, height: 1.7),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(ctx),
                            child: const Text('إغلاق'),
                          ),
                        ],
                      ),
                    );
                  },
                  icon: const Icon(Icons.bug_report_outlined, size: 18),
                  label: const Text('تشخيص الاستماع بالخلفية',
                      style: TextStyle(fontSize: 12)),
                ),
                const SizedBox(height: 12),

                // ═══ اختبار الموصل ═══
                // اختباران متدرّجان يفصلان «الشبكة معطلة» من «المفتاح خاطئ»
                // — وهما عطلان يختلطان على المستخدم كثيراً.
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFF7FD1DA),
                          side: const BorderSide(color: Color(0xFF22344A)),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                        onPressed: testing
                            ? null
                            : () async {
                                setDialogState(() => testing = true);
                                final r = await GeminiService.testReachability(
                                  overrideProviderId: selectedId,
                                  overrideEndpoint: endpointController.text,
                                  overrideModel: modelController.text,
                                );
                                if (!mounted) return;
                                setDialogState(() => testing = false);
                                _showConnectorReport(r, reachability: true);
                              },
                        icon: const Icon(Icons.wifi_tethering, size: 18),
                        label: const Text(
                          'اختبار الوصول',
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFF0E7C86),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                        onPressed: testing || keyController.text.trim().isEmpty
                            ? null
                            : () async {
                                setDialogState(() => testing = true);
                                final r = await GeminiService.testConnection(
                                  overrideProviderId: selectedId,
                                  overrideEndpoint: endpointController.text,
                                  overrideModel: modelController.text,
                                  overrideKey: keyController.text,
                                );
                                if (!mounted) return;
                                setDialogState(() => testing = false);
                                _showConnectorReport(r);
                              },
                        icon: testing
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(Icons.bolt, size: 18),
                        label: Text(
                          testing ? 'جارٍ الاختبار…' : 'اختبار بالمفتاح',
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                const Text(
                  '«الوصول» يتحقق من الشبكة والـ endpoint دون الحاجة لمفتاح صالح.\n'
                  '«بالمفتاح» يرسل طلباً حقيقياً ويعرض ردّ النموذج.',
                  style: TextStyle(color: Colors.white38, fontSize: 10.5, height: 1.5),
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
                // الاستماع الدائم يعمل تلقائياً كـ«هاي جوجل» بلا مفتاح —
                // يسمع اسم النداء المحفوظ أعلاه ويستجيب بالتطبيق والخلفية.
                const Text(
                  'الاستماع تلقائي دائم: يعمل داخل التطبيق وبالخلفية والشاشة '
                  'مقفلة، ويستجيب فور سماع اسم النداء المحفوظ أعلاه.',
                  style: TextStyle(color: Colors.white38, fontSize: 11, height: 1.6),
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

  /// عرض تقرير اختبار الموصل في حوار مقروء — مع تشخيص قابل للتنفيذ.
  ///
  /// [reachability] تميّز اختبار الوصول (بلا مفتاح صالح) عن الاختبار الكامل.
  void _showConnectorReport(ConnectorTestResult r, {bool reachability = false}) {
    // تشخيص نوع العطل واقتراح الحل — بدل ترك المستخدم أمام رمز HTTP
    final failure = OfflineAssistant.classifyError(
      r.errorText,
      statusCode: r.statusCode,
    );
    final advice = r.ok ? null : OfflineAssistant.adviceFor(failure);

    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF131F2E),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: Color(0xFF22344A)),
        ),
        title: Row(
          children: [
            Icon(
              r.ok ? Icons.check_circle : Icons.error,
              color: r.ok ? const Color(0xFF35C77B) : const Color(0xFFE05B4C),
              size: 22,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                r.ok
                    ? (reachability ? 'الشبكة سليمة' : 'الموصل يعمل')
                    : (reachability ? 'تعذّر الوصول' : 'الموصل فشل'),
                style: const TextStyle(color: Colors.white, fontSize: 16),
              ),
            ),
          ],
        ),
        content: SingleChildScrollView(
          child: Directionality(
            textDirection: TextDirection.rtl,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                _reportLine('المزود', r.providerLabel),
                _reportLine('الموديل', r.model),
                _reportLine(
                  'رمز الاستجابة',
                  r.statusCode == 0 ? 'لا استجابة (لم يصل الطلب)' : 'HTTP ${r.statusCode}',
                ),
                _reportLine('زمن الاستجابة', '${r.latencyMs} مللي ثانية'),
                const SizedBox(height: 8),
                SelectableText(
                  r.endpoint,
                  style: const TextStyle(
                    color: Colors.white38,
                    fontSize: 10.5,
                    fontFamily: 'monospace',
                  ),
                ),
                if (r.sampleReply != null && r.sampleReply!.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  const Text(
                    'ردّ النموذج:',
                    style: TextStyle(color: Color(0xFF7FD1DA), fontSize: 12),
                  ),
                  const SizedBox(height: 4),
                  SelectableText(
                    r.sampleReply!,
                    style: const TextStyle(color: Colors.white, fontSize: 12.5),
                  ),
                ],
                if (r.errorText != null && r.errorText!.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  const Text(
                    'رسالة المزود:',
                    style: TextStyle(color: Color(0xFFE05B4C), fontSize: 12),
                  ),
                  const SizedBox(height: 4),
                  SelectableText(
                    r.errorText!,
                    style: const TextStyle(color: Colors.white70, fontSize: 11.5),
                  ),
                ],
                if (advice != null) ...[
                  const SizedBox(height: 14),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1B2B3F),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(
                          Icons.lightbulb_outline,
                          color: Color(0xFFE8C468),
                          size: 18,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            advice,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 11.5,
                              height: 1.5,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                if (!r.ok) ...[
                  const SizedBox(height: 10),
                  const Text(
                    'ملاحظة: كل أوامر الجهاز (شبكة، تطبيقات، اتصال، جدولة) '
                    'تعمل دون هذا الموصل — هو للحوار الحر والأوامر الغامضة فقط.',
                    style: TextStyle(color: Colors.white38, fontSize: 10.5, height: 1.5),
                  ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('إغلاق'),
          ),
        ],
      ),
    );
  }

  Widget _reportLine(String label, String value) => Padding(
        padding: const EdgeInsets.only(bottom: 5),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 96,
              child: Text(
                label,
                style: const TextStyle(color: Colors.white38, fontSize: 11.5),
              ),
            ),
            Expanded(
              child: Text(
                value,
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
            ),
          ],
        ),
      );

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
        final Widget bubble = entry.isUser
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
        final Widget withBadge = (!entry.isUser && entry.source != null)
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(10, 6, 0, 0),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.smart_toy_outlined,
                            size: 11, color: Color(0xFF7FD1DA)),
                        const SizedBox(width: 3),
                        Text(
                          entry.source!,
                          style: const TextStyle(
                            fontSize: 10,
                            color: Color(0xFF7FD1DA),
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                  bubble,
                ],
              )
            : bubble;
        return GestureDetector(
          onLongPress: () => _messageMenu(index),
          child: withBadge,
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
      AgentDispatchStatus.degraded => '🔧',
      AgentDispatchStatus.failed => '❌',
      AgentDispatchStatus.unknownCommand => '❓',
    };
  }

  static String _titleFor(AgentDispatchStatus status) {
    return switch (status) {
      AgentDispatchStatus.executed => 'تم تنفيذ الأمر بنجاح',
      AgentDispatchStatus.scheduled => 'تمت جدولة المهمة بنجاح',
      AgentDispatchStatus.needsConfirmation => 'مطلوب تأكيد عملية حساسة',
      AgentDispatchStatus.degraded => 'نُفّذ بطريقة بديلة',
      AgentDispatchStatus.failed => 'فشل التنفيذ',
      AgentDispatchStatus.unknownCommand => 'أمر غير معروف',
    };
  }

  static Color _colorFor(AgentDispatchStatus status) {
    return switch (status) {
      AgentDispatchStatus.executed => const Color(0xFF35C77B),
      AgentDispatchStatus.scheduled => const Color(0xFF5AB8F0),
      AgentDispatchStatus.needsConfirmation => const Color(0xFFF0A85A),
      AgentDispatchStatus.degraded => const Color(0xFFE8C468),
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
