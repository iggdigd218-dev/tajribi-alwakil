import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show MethodChannel, PlatformException;

import '../models/agent_action_intent.dart';
import 'device_knowledge_service.dart';

/// نتيجة خام من الموصل — تفصل «النص» عن «رمز HTTP» عن «رسالة الخطأ»
/// حتى يستطيع المستدعي تشخيص العطل بدقة بدل التخمين.
class _RawCompletion {
  const _RawCompletion({
    required this.text,
    required this.statusCode,
    required this.error,
  });

  final String? text;
  final int statusCode;
  final String? error;

  bool get isOk => text != null && text!.isNotEmpty;
}

/// مزود OpenAI-compatible.
class AiProviderInfo {
  const AiProviderInfo({
    required this.id,
    required this.label,
    required this.endpoint,
    required this.defaultModel,
    this.style = ConnectorStyle.openAi,
    this.authHeader = 'Authorization',
    this.authPrefix = 'Bearer ',
  });

  final String id;
  final String label;
  final String endpoint;
  final String defaultModel;

  /// أسلوب الواجهة البرمجية — يحدد شكل جسم الطلب وطريقة قراءة الرد.
  final ConnectorStyle style;

  /// ترويسة المصادقة واسمها.
  final String authHeader;
  final String authPrefix;
}

/// أسلوب الموصل: كيف نتكلم مع المزود.
enum ConnectorStyle {
  /// Chat Completions الموحد — Groq/OpenRouter/OpenAI/DeepSeek وأي متوافق.
  openAi,

  /// Gemini REST الأصلي — جسم `contents` ورد `candidates` ومفتاح
  /// عبر ترويسة `x-goog-api-key` (لا `Authorization: Bearer`).
  gemini,
}

/// نتيجة اختبار حيّ للموصل — تُعرض في الإعدادات لتشخيص العطل بدقة.
class ConnectorTestResult {
  const ConnectorTestResult({
    required this.ok,
    required this.statusCode,
    required this.latencyMs,
    required this.providerLabel,
    required this.endpoint,
    required this.model,
    this.sampleReply,
    this.errorText,
  });

  final bool ok;
  final int statusCode;
  final int latencyMs;
  final String providerLabel;
  final String endpoint;
  final String model;
  final String? sampleReply;
  final String? errorText;

  /// تقرير عربي مقروء يشرح ما حدث بالضبط — يُعرض للمستخدم.
  String get report {
    final head = ok
        ? '✅ الموصل يعمل مع $providerLabel'
        : '❌ الموصل فشل مع $providerLabel';
    final lines = <String>[
      head,
      'الرمز: ${statusCode == 0 ? 'لا استجابة' : 'HTTP $statusCode'}  •  '
          'الزمن: $latencyMs مللي ثانية',
      'الموديل: $model',
      'الـ endpoint: $endpoint',
    ];
    if (ok && sampleReply != null && sampleReply!.isNotEmpty) {
      lines.add('ردّ النموذج: $sampleReply');
    }
    if (!ok && errorText != null) {
      lines.add('رسالة المزود: $errorText');
    }
    return lines.join('\n');
  }
}

/// ناتج معالجة أمر عبر المحرك السحابي.
class GeminiVoiceOutcome {
  const GeminiVoiceOutcome({
    required this.reply,
    required this.actions,
    this.error,
    this.statusCode = 0,
  });

  final String reply;
  final List<AgentActionIntent> actions;
  final String? error;

  /// رمز HTTP من المزود — 0 يعني أن الطلب لم يصل أصلاً.
  /// يُستخدم لتشخيص نوع العطل (401 مصادقة، 429 حد، 404 موديل، 5xx خادم).
  final int statusCode;

  bool get hasError => error != null;
}

/// عميل Chat Completions الموحد (Groq / OpenRouter / OpenAI / DeepSeek / Custom).
///
/// يبقى الاسم [GeminiService] لتوافق VoiceService والشات.
class GeminiService {
  GeminiService._();

  static const MethodChannel _settingsChannel =
      MethodChannel('com.example.app/settings');

  static const Duration _timeout = Duration(seconds: 30);

  /// UA صريح: بوابات بعض المزودين (Groq/Cloudflare) ترفض UA الافتراضي
  /// «Dart/x.x (dart:io)» برمز 403 — اختُبر هذا حياً 2026-09-15.
  static const String userAgent =
      'AgentAutomation/1.3 (Linux; Android 14) Mobile Connector';

  static const List<AiProviderInfo> providers = [
    AiProviderInfo(
      id: 'groq',
      label: 'Groq',
      endpoint: 'https://api.groq.com/openai/v1/chat/completions',
      // qwen/qwen3.8-27b: اختُبر حياً 2026-09-15 — يلتزم ببروتوكول
      // JSON الخاص بالتطبيق التزاماً كاملاً (llama-3.3-70b سُحب من Groq).
      defaultModel: 'qwen/qwen3.8-27b',
    ),
    AiProviderInfo(
      id: 'gemini',
      label: 'Google Gemini',
      // ⚠️ أسلوب Gemini الأصلي يختلف عن Chat Completions:
      //    جسم الطلب `contents` والرد `candidates` والمفتاح في
      //    ترويسة `x-goog-api-key` — لذلك style: gemini.
      endpoint:
          'https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent',
      // `gemini-flash-latest` اسم مستعار يوجّه لأحدث موديل Flash متاح،
      // فلا ينكسر التطبيق عندما تُسحب إصدارات مرقمة (1.5-flash مثلاً).
      defaultModel: 'gemini-flash-latest',
      style: ConnectorStyle.gemini,
      authHeader: 'x-goog-api-key',
      authPrefix: '',
    ),
    AiProviderInfo(
      id: 'openrouter',
      label: 'OpenRouter',
      endpoint: 'https://openrouter.ai/api/v1/chat/completions',
      defaultModel: 'meta-llama/llama-3.3-70b-instruct:free',
    ),
    AiProviderInfo(
      id: 'openai',
      label: 'OpenAI',
      endpoint: 'https://api.openai.com/v1/chat/completions',
      defaultModel: 'gpt-4o-mini',
    ),
    AiProviderInfo(
      id: 'deepseek',
      label: 'DeepSeek',
      endpoint: 'https://api.deepseek.com/chat/completions',
      defaultModel: 'deepseek-chat',
    ),
    AiProviderInfo(
      id: 'custom',
      label: 'Custom',
      endpoint: '',
      defaultModel: '',
    ),
  ];

  static AiProviderInfo byId(String id) =>
      providers.firstWhere((p) => p.id == id, orElse: () => providers.first);

  /// المزود الفعلي الحالي (يحلّ `custom` إلى أسلوب OpenAI-compat).
  static AiProviderInfo get currentProvider => byId(providerId);

  static String providerId = 'groq';
  static String endpoint =
      'https://api.groq.com/openai/v1/chat/completions';
  static String model = 'qwen/qwen3.8-27b';
  static String? _programmaticKey;

  // ══════════════════════════════════════════════════════════
  //  المفتاح المدمج (الحقن الرسمي) — يعمل به التطبيق مباشرة
  // ══════════════════════════════════════════════════════════
  /// مفتاح Groq المحقون رسمياً مع التطبيق — **منفصل تماماً** عن
  /// مفتاح المستخدم الذي يُدخل في شاشة الإعدادات.
  ///
  /// الحقن يتم **زمن الترجمة** عبر:
  ///   flutter build apk --dart-define=AGENT_BUILTIN_GROQ_KEY=‹المفتاح›
  /// (سكربتات build_lowmem.sh / build_apk.sh تمرّره تلقائياً) —
  /// فيعيش المفتاح داخل الـ APK الرسمي ولا يدخل تاريخ Git أبداً
  /// (حماية GitHub pushing ترفض دفع مفاتيح Groq الحية للمستودعات).
  /// أولوية الاستخدام: مفتاح الإعدادات > متغير GEMINI_API_KEY > المدمج.
  static const String builtInApiKey =
      String.fromEnvironment('AGENT_BUILTIN_GROQ_KEY');
  static const String builtInProviderId = 'groq';
  static const String builtInModel = 'qwen/qwen3.8-27b';

  /// هل يعمل التطبيق الآن على المفتاح المدمج (لا مفتاح مستخدم)؟
  static bool get isUsingBuiltInKey =>
      builtInApiKey.isNotEmpty &&
      _programmaticKey == null &&
      const String.fromEnvironment('GEMINI_API_KEY').isEmpty &&
      providerId == builtInProviderId;

  static String get apiKey {
    final user = _programmaticKey;
    if (user != null && user.isNotEmpty) return user;
    final env = const String.fromEnvironment('GEMINI_API_KEY');
    if (env.isNotEmpty) return env;
    // المفتاح المدمج صالح لمزوده فقط — لا يُرسل لغير Groq أبداً
    if (providerId == builtInProviderId) return builtInApiKey;
    return '';
  }

  static set apiKey(String? value) => _programmaticKey =
      (value == null || value.trim().isEmpty) ? null : value.trim();

  static bool get isConfigured =>
      apiKey.isNotEmpty && endpoint.trim().isNotEmpty && model.trim().isNotEmpty;

  static String get providerLabel => byId(providerId).label;

  static const String _systemPrompt = '''
أنت "الوكيل": مساعد شخصي ذكر، وقور، سريع البديهة، ومحترم.
تتحاور بالعربية الفصحى المبسطة بنبرة رصينة هادئة تناسب الرد الصوتي.
أنت مساعد ذكي للأتمتة والتحكم بالنظام باللغة العربية. تعرف جهاز المستخدم: تطبيقاته المثبتة وحالته، وتستطيع تنفيذ الأوامر عليه.

قواعد صارمة:
1. حقل reply جملة أو جملتان قصيرتان كحد أقصى — سيُنطق صوتياً فوراً.
2. ممنوع في reply: الرموز، النجوم، الجداول، الأكواد، الإيموجي.
3. حوار عام بلا طلب تنفيذي → اجعل actions مصفوفة فارغة.
4. طلب تنفيذي → املأ actions. أمر واحد لكل طلب إلا إن طلب المستخدم صراحةً أكثر.
5. requiresConfirmation = true للعمليات المالية والهدّامة (إلغاء تثبيت، مسح بيانات، إعادة تشغيل الجهاز).
6. slotIndex مبني على الصفر: الشريحة الأولى 0، الثانية 1.
7. scheduledTime بصيغة ISO8601 للطلبات المؤجلة، وإلا null.
8. packageName: استخدمه فقط إن كان التطبيق موجوداً فعلاً في قائمة «التطبيقات المثبتة» أدناه. لا تخترع معرّفات.
9. إن طلب المستخدم تطبيقاً غير مثبت، اشرح ذلك في reply واترك actions فارغة.
10. الأسئلة عن الجهاز نفسه (البطارية، التخزين، التطبيقات المثبتة، حالة الصلاحيات) يجيب عنها التطبيق محلياً — لا تحتاج actions.

أنواع الأوامر المتاحة في actionType:
■ نظام: toggle_wifi, toggle_mobile_data, toggle_bluetooth, toggle_airplane, toggle_flashlight, set_brightness, set_volume, toggle_rotation, set_dnd, lock_screen, reboot_device, screenshot, open_settings_page, navigate_ui (target: back|home|recents), shell_command (parameters.command)
■ تطبيقات: open_app, app_info, uninstall_app, force_stop_app, clear_app_cache, app_files, list_apps
■ ملفات: list_files (parameters.path), find_file (parameters.query, parameters.path), storage_info
■ اتصال ورسائل: call (phoneNumber, slotIndex), send_message (phoneNumber, text), send_email (to, subject, body), open_contacts
■ وسائط: media_control (op: play|pause|next|prev), open_camera
■ ويب: open_url (url), search_web (query)
■ واجهة تطبيق مفتوح: ui_click (text أو viewId), ui_set_text (text أو viewId, value), input_tap (x, y), input_text (text)
■ مالي: payment (walletName, amount, phoneNumber)

معاني المعاملات:
- enable: true/false لأوامر التشغيل والإطفاء.
- percent: رقم 0-100 للسطوع والصوت.
- op: play|pause|next|prev للوسائط.
- target: back|home|recents للتنقل في الواجهة.
- path: مسار مطلق مثل /sdcard/Download.
- query: كلمة البحث في الملفات أو الويب.

أعد دائماً JSON صالحاً فقط بهذه البنية:
{
  "reply": "رد قصير للنطق",
  "actions": [
    {
      "actionType": "open_app",
      "category": "system | automation | scheduler | payment | call | apps | files | device | media | messaging | info",
      "targetApp": "اسم التطبيق أو null",
      "parameters": { },
      "scheduledTime": null,
      "requiresConfirmation": false
    }
  ]
}

أمثلة:
"صباح الخير" → {"reply":"صباح النور والبركة، كيف حالك اليوم؟","actions":[]}
"الووو" → {"reply":"وعليكم السلام، تفضل أمرك.","actions":[]}
"اطفئ النت بعد ربع ساعة" → {"reply":"حسناً، سأطفئ بيانات الجوال بعد ربع ساعة.","actions":[{"actionType":"toggle_mobile_data","category":"system","targetApp":null,"parameters":{"enable":false},"scheduledTime":null,"requiresConfirmation":false}]}
"نور الكشاف" → {"reply":"سأشعل الكشاف.","actions":[{"actionType":"toggle_flashlight","category":"system","targetApp":null,"parameters":{"enable":true},"scheduledTime":null,"requiresConfirmation":false}]}
"خفض السطوع للنص" → {"reply":"سأضبط السطوع على خمسين بالمئة.","actions":[{"actionType":"set_brightness","category":"system","targetApp":null,"parameters":{"percent":50},"scheduledTime":null,"requiresConfirmation":false}]}
"ارجع للخلف" → {"reply":"سأعود للخلف.","actions":[{"actionType":"navigate_ui","category":"automation","targetApp":null,"parameters":{"target":"back"},"scheduledTime":null,"requiresConfirmation":false}]}
"شيل تطبيق تيك توك" → {"reply":"سأطلب تأكيد إلغاء تثبيت تيك توك.","actions":[{"actionType":"uninstall_app","category":"apps","targetApp":"تيك توك","parameters":{"packageName":"com.zhiliaoapp.musically"},"scheduledTime":null,"requiresConfirmation":true}]}
"اعرض ملفات التنزيلات" → {"reply":"سأعرض محتويات مجلد التنزيلات.","actions":[{"actionType":"list_files","category":"files","targetApp":null,"parameters":{"path":"/sdcard/Download"},"scheduledTime":null,"requiresConfirmation":false}]}
"دور على ملفات بي دي اف" → {"reply":"سأبحث عن ملفات PDF.","actions":[{"actionType":"find_file","category":"files","targetApp":null,"parameters":{"query":"*.pdf","path":"/sdcard"},"scheduledTime":null,"requiresConfirmation":false}]}
"وقف الموسيقى" → {"reply":"سأوقف الوسائط مؤقتاً.","actions":[{"actionType":"media_control","category":"media","targetApp":null,"parameters":{"op":"pause"},"scheduledTime":null,"requiresConfirmation":false}]}
"ابحث عن سعر الذهب" → {"reply":"سأبحث عن سعر الذهب في المتصفح.","actions":[{"actionType":"search_web","category":"info","targetApp":null,"parameters":{"query":"سعر الذهب"},"scheduledTime":null,"requiresConfirmation":false}]}
"كم البطارية؟" → {"reply":"البطارية عند 78 بالمئة وليست على الشاحن.","actions":[]}
"اتصل بمحمد فتح من الشريحة 1" → {"reply":"سأتصل بمحمد فتح من الشريحة الأولى.","actions":[{"actionType":"call","category":"call","targetApp":null,"parameters":{"contactName":"محمد فتح","slotIndex":0},"scheduledTime":null,"requiresConfirmation":false}]}

قواعد الاتصال وجهات الاتصال (مهمة جداً):
- «اتصل بـX» أو «اتصل بـX من الشريحة/الشريحة رقم N/سيم N»: أرسل actionType=call مع parameters {"contactName":"X","slotIndex":N-1} — ولا تخترع رقماً.
- الشريحة/السيم/الخط ليست تطبيقاً — لا تفتح لها تطبيقاً ولا تجعلها targetApp أبداً.
- «ابحث في جهات الاتصال عن X واتصل به» أو «ابحث انت واتصل انت»: نفس إجراء call بالـ contactName — البحث في المتصفح ممنوع هنا.
- استخدم phoneNumber فقط إن نطق المستخدم رقماً صريحاً.
''';

  static Future<void> loadSavedKey() async {
    try {
      final map = await _settingsChannel
          .invokeMapMethod<String, dynamic>('getAiSettings');
      if (map == null) {
        final saved =
            await _settingsChannel.invokeMethod<String>('getGeminiApiKey');
        if (saved != null && saved.trim().isNotEmpty) {
          _programmaticKey = saved.trim();
        }
        return;
      }
      final pid = (map['provider'] as String?)?.trim();
      if (pid != null && pid.isNotEmpty) providerId = pid;
      final ep = (map['endpoint'] as String?)?.trim();
      if (ep != null && ep.isNotEmpty) {
        endpoint = ep;
      } else {
        endpoint = byId(providerId).endpoint;
      }
      final md = (map['model'] as String?)?.trim();
      if (md != null && md.isNotEmpty) {
        model = md;
      } else {
        model = byId(providerId).defaultModel;
      }
      final key = (map['apiKey'] as String?)?.trim();
      if (key != null && key.isNotEmpty) {
        _programmaticKey = key;
      }
      // ── إصلاح ذاتي: نموذج/نقطة نهاية محفوظان لمزود آخر يفسدان الطلب
      // (مثل مفتاح Gemini مع نموذج Groq محفوظ سابقاً) — يُصححان تلقائياً ──
      if (providerId != 'custom') {
        final info = byId(providerId);
        if (info.style == ConnectorStyle.gemini) {
          if (!model.startsWith('gemini')) model = info.defaultModel;
          if (!endpoint.contains('generativelanguage.googleapis.com')) {
            endpoint = info.endpoint;
          }
        } else {
          if (model.startsWith('gemini-')) model = info.defaultModel;
          final defHost = Uri.tryParse(info.endpoint)?.host ?? '';
          final curHost = Uri.tryParse(endpoint)?.host ?? '';
          if (defHost.isNotEmpty && curHost.isNotEmpty && curHost != defHost) {
            endpoint = info.endpoint;
          }
        }
      }
    } on PlatformException {
      // القناة غير جاهزة
    }
  }

  static Future<bool> saveApiKey(String key) async {
    return saveSettings(
      provider: providerId,
      endpoint: endpoint,
      model: model,
      apiKey: key,
    );
  }

  static Future<bool> saveSettings({
    required String provider,
    required String endpoint,
    required String model,
    required String apiKey,
  }) async {
    final cleanKey = apiKey.trim();
    if (cleanKey.isEmpty) return false;
    final info = byId(provider);
    final ep = endpoint.trim().isEmpty ? info.endpoint : endpoint.trim();
    final md = model.trim().isEmpty ? info.defaultModel : model.trim();
    try {
      final ok = await _settingsChannel.invokeMethod<bool>('setAiSettings', {
            'provider': info.id,
            'endpoint': ep,
            'model': md,
            'apiKey': cleanKey,
          }) ??
          false;
      if (ok) {
        providerId = info.id;
        GeminiService.endpoint = ep;
        GeminiService.model = md;
        _programmaticKey = cleanKey;
      }
      return ok;
    } on PlatformException {
      return false;
    }
  }

  static Future<bool> clearApiKey() async {
    try {
      final ok =
          await _settingsChannel.invokeMethod<bool>('clearGeminiApiKey') ??
              false;
      if (ok) _programmaticKey = null;
      return ok;
    } on PlatformException {
      return false;
    }
  }

  static Future<GeminiVoiceOutcome> processVoiceCommand(
    String userText, {
    List<Map<String, Object?>>? history,
  }) async {
    if (!isConfigured) {
      return const GeminiVoiceOutcome(
        reply: '',
        actions: [],
        error: 'مفتاح الذكاء الاصطناعي غير مضبوط — افتح ⚙️ واختر المزود',
        statusCode: 0,
      );
    }
    if (userText.trim().isEmpty) {
      return const GeminiVoiceOutcome(reply: '', actions: [], error: 'نص فارغ');
    }

    // نحدّث معرفة الجهاز قبل الاستدعاء حتى يكون الموجه مطابقاً للواقع
    await refreshDeviceContext();

    // محاولة مع إعادة واحدة عند الأعطال العابرة (شبكة/مهلة/5xx)
    var raw = await _chatCompletions(userText: userText, history: history);
    if (!raw.isOk && _isTransient(raw)) {
      await Future<void>.delayed(const Duration(milliseconds: 600));
      raw = await _chatCompletions(userText: userText, history: history);
    }

    if (!raw.isOk) {
      return GeminiVoiceOutcome(
        reply: '',
        actions: const [],
        error: raw.error ?? 'لم يرجع النموذج نصاً',
        statusCode: raw.statusCode,
      );
    }

    final text = raw.text!;
    final map = _decodeLooseJson(text);
    if (map == null) {
      // ردّ نصي عادي بدل JSON — نتعامل معه كحوار (ولا نرميه)
      return GeminiVoiceOutcome(reply: text.trim(), actions: const []);
    }

    final reply = (map['reply'] as String?)?.trim() ?? '';
    final actions = <AgentActionIntent>[];
    final rawActions = map['actions'];
    if (rawActions is List) {
      for (final item in rawActions) {
        if (item is Map) {
          final json = Map<String, dynamic>.from(item);
          json['rawText'] = userText;
          json.putIfAbsent(
            'id',
            () => 'voice_${DateTime.now().microsecondsSinceEpoch}',
          );
          // نتجاهل أنواع الأوامر المجهولة بدل تمريرها للمفرّق ليفشل عليها
          final type = json['actionType'] as String? ?? '';
          if (type.isNotEmpty && !AgentActionTypes.isKnown(type)) continue;
          actions.add(AgentActionIntent.fromJson(json));
        }
      }
    }
    return GeminiVoiceOutcome(
      reply: reply.isEmpty ? text.trim() : reply,
      actions: actions,
      statusCode: raw.statusCode,
    );
  }

  /// هل العطل عابر يستحق إعادة المحاولة؟
  static bool _isTransient(_RawCompletion raw) {
    final c = raw.statusCode;
    if (c == 0 || c == 408 || c == 425 || c == 429) return true;
    return c >= 500 && c < 600;
  }

  // ═══════════════════════════════════════════
  //  سياق الجهاز — ما يجعل الذكاء يعرف جهاز المستخدم فعلياً
  // ═══════════════════════════════════════════

  /// جرد التطبيقات المثبتة كما حُقن في آخر موجه (يُحدَّث عند الطلب).
  static String _appInventory = '';
  static String _deviceFacts = '';
  static DateTime _contextTime = DateTime.fromMillisecondsSinceEpoch(0);

  /// صلاحية سياق الجهاز — لا داعي لإعادة الجرد مع كل رسالة.
  static const Duration _contextTtl = Duration(minutes: 10);

  /// تحديث جرد التطبيقات وحقائق الجهاز من الطبقة الأصلية.
  ///
  /// يُستدعى تلقائياً قبل كل طلب سحابي (مع احترام المهلة)، ويمكن استدعاؤه
  /// يدوياً بعد تثبيت/إلغاء تطبيق.
  static Future<void> refreshDeviceContext({bool force = false}) async {
    final now = DateTime.now();
    if (!force && now.difference(_contextTime) < _contextTtl) return;
    try {
      _appInventory = await DeviceKnowledgeService.promptInventory();
      final snap = await DeviceKnowledgeService.deviceSnapshot();
      _deviceFacts = [
        'الجهاز: ${snap.model}',
        'أندرويد: ${snap.androidVersion} (API ${snap.sdkInt})',
        if (snap.batteryPercent >= 0) 'البطارية: ${snap.batteryPercent}%',
        if (snap.storageTotalBytes > 0)
          'المساحة المتاحة: '
              '${DeviceKnowledgeService.humanSize(snap.storageFreeBytes)}',
        'إمكانية الوصول: ${snap.accessibilityEnabled ? 'مفعّلة' : 'معطّلة'}',
        'Shizuku: ${snap.shizukuGranted ? 'مرخّص' : snap.shizukuRunning ? 'بلا ترخيص' : 'غير مشغّل'}',
        'الوقت المحلي: ${snap.currentTime}',
      ].join(' • ');
      _contextTime = now;
    } catch (_) {
      // معرفة الجهاز تكميلية — فشلها لا يجب أن يوقف المحادثة
    }
  }

  /// الموجه الفعلي = الموجه الثابت + معرفة الجهاز الحيّة.
  ///
  /// حقن جرد التطبيقات يجعل النموذج يعيد `packageName` الصحيح لتطبيق
  /// المستخدم الحقيقي بدل أن يخمّن معرّفاً غير موجود — وهو ما كان
  /// يسبب فشل «افتح X» عند الاعتماد على خريطة مكتوبة يدوياً.
  static String get _effectiveSystemPrompt {
    final sb = StringBuffer(_systemPrompt);
    if (_deviceFacts.isNotEmpty) {
      sb.write('\n\nمعلومات جهاز المستخدم الحالية (حقيقية ومقروءة من النظام):\n');
      sb.write(_deviceFacts);
    }
    if (_appInventory.isNotEmpty) {
      sb.write('\n\nالتطبيقات المثبتة فعلياً على جهاز المستخدم '
          'بصيغة «الاسم [معرّف الحزمة]» — استخدم معرّف الحزمة كما هو '
          'في packageName ولا تخمّن معرّفاً غير موجود هنا:\n');
      sb.write(_appInventory);
      sb.write('\nإن طلب المستخدم تطبيقاً غير موجود في هذه القائمة، '
          'فلا تخترع معرّفاً: أعد reply يوضح أنه غير مثبت واجعل actions فارغة.');
    }
    return sb.toString();
  }

  /// نتيجة خام من الموصل: النص + رمز HTTP + الخطأ (للتشخيص الدقيق).
  static Future<_RawCompletion> _chatCompletions({
    required String userText,
    List<Map<String, Object?>>? history,
    Duration timeout = _timeout,
  }) async {
    final info = currentProvider;
    final uri = Uri.parse(_resolvedEndpoint(info));

    final body = info.style == ConnectorStyle.gemini
        ? _buildGeminiBody(userText, history)
        : _buildOpenAiBody(userText, history);

    final client = HttpClient()
      ..connectionTimeout = timeout
      ..userAgent = userAgent;
    try {
      final request = await client.postUrl(uri).timeout(timeout);
      request.headers.set(
        HttpHeaders.contentTypeHeader,
        'application/json; charset=utf-8',
      );
      // المصادقة: ترويسة المزود نفسه (Bearer للموحّد، x-goog-api-key لـ Gemini)
      request.headers.set(info.authHeader, '${info.authPrefix}$apiKey');
      // ترويسات اختيارية يطلبها OpenRouter لإحصاءاته — لا تضر بغيره
      request.headers.set('HTTP-Referer', 'https://agent-automation.local');
      request.headers.set('X-Title', 'Agent Automation');
      request.add(utf8.encode(body));

      final response = await request.close().timeout(timeout);
      final responseBody = await response.transform(utf8.decoder).join();

      if (response.statusCode != 200) {
        return _RawCompletion(
          text: null,
          statusCode: response.statusCode,
          error: _extractProviderError(responseBody, response.statusCode),
        );
      }

      final content = info.style == ConnectorStyle.gemini
          ? _parseGeminiResponse(responseBody)
          : _parseOpenAiResponse(responseBody);

      if (content == null || content.trim().isEmpty) {
        return _RawCompletion(
          text: null,
          statusCode: response.statusCode,
          error: 'المزود ردّ بـ HTTP 200 لكن دون نص قابل للاستخدام',
        );
      }
      return _RawCompletion(
        text: content,
        statusCode: response.statusCode,
        error: null,
      );
    } on SocketException catch (e) {
      return _RawCompletion(
        text: null,
        statusCode: 0,
        error: 'لا اتصال بالإنترنت (${e.osError?.message ?? e.message})',
      );
    } on TimeoutException {
      return _RawCompletion(
        text: null,
        statusCode: 0,
        error: 'انتهت مهلة الاتصال (${timeout.inSeconds} ثانية)',
      );
    } on HandshakeException catch (e) {
      return _RawCompletion(
        text: null,
        statusCode: 0,
        error: 'فشل TLS/الشهادة: ${e.message}',
      );
    } on HttpException catch (e) {
      return _RawCompletion(
        text: null,
        statusCode: 0,
        error: 'خطأ HTTP: ${e.message}',
      );
    } on FormatException catch (e) {
      return _RawCompletion(
        text: null,
        statusCode: 200,
        error: 'رد المزود ليس JSON صالحاً: ${e.message}',
      );
    } catch (e) {
      return _RawCompletion(text: null, statusCode: 0, error: e.toString());
    } finally {
      client.close(force: true);
    }
  }

  /// يستبدل `{model}` في الـ endpoint (أسلوب Gemini يحتاج اسم الموديل في المسار).
  static String _resolvedEndpoint(AiProviderInfo info) {
    final ep = endpoint.trim().isEmpty ? info.endpoint : endpoint.trim();
    return ep.replaceAll('{model}', Uri.encodeComponent(model));
  }

  /// جسم طلب بأسلوب Chat Completions الموحد.
  static String _buildOpenAiBody(
    String userText,
    List<Map<String, Object?>>? history,
  ) {
    final messages = <Map<String, dynamic>>[
      {'role': 'system', 'content': _effectiveSystemPrompt},
      if (history != null)
        for (final entry in history)
          {
            'role': entry['role'] as String? ?? 'user',
            'content': entry['text'] as String? ?? '',
          },
      {'role': 'user', 'content': userText},
    ];
    return jsonEncode(<String, dynamic>{
      'model': model,
      'messages': messages,
      'temperature': 0.3,
    });
  }

  /// جسم طلب بأسلوب Gemini الأصلي.
  static String _buildGeminiBody(
    String userText,
    List<Map<String, Object?>>? history,
  ) {
    return jsonEncode(<String, dynamic>{
      'system_instruction': {
        'parts': [
          {'text': _effectiveSystemPrompt}
        ]
      },
      'contents': [
        if (history != null)
          for (final entry in history)
            {
              'role': (entry['role'] as String? ?? 'user') == 'assistant'
                  ? 'model'
                  : 'user',
              'parts': [
                {'text': entry['text'] as String? ?? ''}
              ]
            },
        {
          'role': 'user',
          'parts': [
            {'text': userText}
          ]
        },
      ],
      'generationConfig': <String, dynamic>{
        'temperature': 0.3,
        'responseMimeType': 'application/json',
      },
    });
  }

  /// موجه طبقة إعادة الصياغة — يصلح أخطاء الاستماع الصوتي والعامية.
  static const String _reformPrompt =
      'أنت طبقة تصحيح أمام وكيل أتمتة أندرويد عربي. يصلك طلب المستخدم كما وصل '
      '(قد يحتوي أخطاء تعرف صوتي أو عامية أو نقصاً). أعد صياغته في جملة واحدة '
      'واضحة بالفصحى المبسطة تحفظ المقصود بدقة: نوع الأمر، الأرقام، أسماء '
      'التطبيقات، الأوقات، أرقام الهواتف. أعد الجملة المصححة فقط دون مقدمات '
      'أو شرح أو علامات اقتباس.';

  /// إعادة صياغة طلب خام (نص استماع صوتي غالباً) إلى أمر قاني واضح.
  /// يعيد null عند غياب الموصل أو أي فشل — فيُستخدم النص الأصلي.
  static Future<String?> reformulateCommand(String raw) async {
    final clean = raw.trim();
    if (clean.isEmpty || !isConfigured) return null;
    final info = currentProvider;
    final uri = Uri.parse(_resolvedEndpoint(info));
    final body = info.style == ConnectorStyle.gemini
        ? jsonEncode(<String, dynamic>{
            'systemInstruction': {
              'parts': [
                {'text': _reformPrompt}
              ]
            },
            'contents': [
              {
                'role': 'user',
                'parts': [
                  {'text': clean}
                ]
              }
            ],
            'generationConfig': <String, dynamic>{'temperature': 0.1},
          })
        : jsonEncode(<String, dynamic>{
            'model': model,
            'messages': <Map<String, dynamic>>[
              {'role': 'system', 'content': _reformPrompt},
              {'role': 'user', 'content': clean},
            ],
            'temperature': 0.1,
          });
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 12)
      ..userAgent = userAgent;
    try {
      final request =
          await client.postUrl(uri).timeout(const Duration(seconds: 12));
      request.headers.set(
        HttpHeaders.contentTypeHeader,
        'application/json; charset=utf-8',
      );
      request.headers.set(info.authHeader, '${info.authPrefix}$apiKey');
      request.add(utf8.encode(body));
      final response =
          await request.close().timeout(const Duration(seconds: 12));
      if (response.statusCode != 200) {
        await response.drain<void>();
        return null;
      }
      final text = await response.transform(utf8.decoder).join();
      final content = info.style == ConnectorStyle.gemini
          ? _parseGeminiResponse(text)
          : _parseOpenAiResponse(text);
      final out = content?.trim().replaceAll(RegExp(r'''^["«»']+|["«»']+$'''), '');
      if (out == null || out.isEmpty || out.length > 300) return null;
      return out;
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// قراءة نص الرد بأسلوب Chat Completions.
  static String? _parseOpenAiResponse(String responseBody) {
    final data = jsonDecode(responseBody);
    if (data is! Map<String, dynamic>) return null;
    final choices = data['choices'];
    if (choices is! List || choices.isEmpty) return null;
    final message = (choices[0] as Map?)?['message'];
    return (message as Map?)?['content'] as String?;
  }

  /// قراءة نص الرد بأسلوب Gemini (يتحمّل finishReason وسلاسل parts متعددة).
  static String? _parseGeminiResponse(String responseBody) {
    final data = jsonDecode(responseBody);
    if (data is! Map<String, dynamic>) return null;
    final candidates = data['candidates'];
    if (candidates is! List || candidates.isEmpty) return null;
    final parts = (candidates[0] as Map?)?['content']?['parts'];
    if (parts is! List || parts.isEmpty) return null;
    final sb = StringBuffer();
    for (final p in parts) {
      final t = (p as Map?)?['text'];
      if (t is String) sb.write(t);
    }
    final out = sb.toString().trim();
    return out.isEmpty ? null : out;
  }

  /// استخراج رسالة الخطأ المفيدة من رد المزود بدل رمي الجسم كاملاً.
  static String _extractProviderError(String responseBody, int statusCode) {
    String snippet = responseBody.trim();
    try {
      final data = jsonDecode(responseBody);
      if (data is Map) {
        final err = data['error'];
        if (err is Map) {
          final msg = err['message'];
          if (msg is String && msg.isNotEmpty) snippet = msg;
          final type = err['type'];
          if (type is String && type.isNotEmpty) snippet = '[$type] $snippet';
        }
      }
    } catch (_) {
      // ليس JSON — نستخدم النص الخام
    }
    if (snippet.length > 500) snippet = '${snippet.substring(0, 500)}…';
    return 'HTTP $statusCode: $snippet';
  }

  // ═══════════════════════════════════════════
  //  اختبار الموصل
  // ═══════════════════════════════════════════

  /// اختبار حيّ للموصل — يُستدعى من زر «اختبار الاتصال» في الإعدادات.
  ///
  /// يرسل طلباً حقيقياً صغيراً ويعيد تشخيصاً كاملاً: رمز HTTP، الزمن،
  /// ردّ النموذج إن نجح، ورسالة المزود الأصلية إن فشل.
  static Future<ConnectorTestResult> testConnection({
    String? overrideKey,
    String? overrideEndpoint,
    String? overrideModel,
    String? overrideProviderId,
  }) async {
    // نسمح باختبار إعدادات لم تُحفظ بعد (أثناء تحرير النموذج)
    final savedProvider = providerId;
    final savedEndpoint = endpoint;
    final savedModel = model;
    final savedKey = _programmaticKey;

    if (overrideProviderId != null) providerId = overrideProviderId;
    if (overrideEndpoint != null) endpoint = overrideEndpoint;
    if (overrideModel != null) model = overrideModel;
    if (overrideKey != null) _programmaticKey = overrideKey.trim();

    final started = DateTime.now();
    try {
      if (!isConfigured) {
        return ConnectorTestResult(
          ok: false,
          statusCode: 0,
          latencyMs: 0,
          providerLabel: providerLabel,
          endpoint: endpoint,
          model: model,
          errorText: 'المفتاح أو الـ endpoint أو الموديل غير مكتمل',
        );
      }

      final raw = await _chatCompletions(
        userText: 'أجب بكلمة واحدة فقط: جاهز',
        timeout: const Duration(seconds: 25),
      );
      final latency = DateTime.now().difference(started).inMilliseconds;

      return ConnectorTestResult(
        ok: raw.text != null,
        statusCode: raw.statusCode,
        latencyMs: latency,
        providerLabel: providerLabel,
        endpoint: _resolvedEndpoint(currentProvider),
        model: model,
        sampleReply: raw.text,
        errorText: raw.error,
      );
    } finally {
      // نعيد الإعدادات المحفوظة كما كانت
      providerId = savedProvider;
      endpoint = savedEndpoint;
      model = savedModel;
      _programmaticKey = savedKey;
    }
  }

  /// فحص سريع لوصول الـ endpoint دون مفتاح صالح.
  ///
  /// يميّز «الشبكة/الـ DNS/TLS معطلة» من «المفتاح خاطئ» — وهما عطلان
  /// يختلطان على المستخدم كثيراً. رمز 401/403 هنا **يعني أن الاتصال سليم**.
  static Future<ConnectorTestResult> testReachability({
    String? overrideEndpoint,
    String? overrideModel,
    String? overrideProviderId,
  }) async {
    final savedProvider = providerId;
    final savedEndpoint = endpoint;
    final savedModel = model;
    if (overrideProviderId != null) providerId = overrideProviderId;
    if (overrideEndpoint != null) endpoint = overrideEndpoint;
    if (overrideModel != null) model = overrideModel;

    final info = currentProvider;
    final uri = Uri.parse(_resolvedEndpoint(info));
    final started = DateTime.now();

    final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 12)
        ..userAgent = userAgent;
    try {
      final request = await client.postUrl(uri);
      request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      // ترويسة أخرى لاختبار المصادقة حسب أسلوب المزود
      if (info.authHeader.toLowerCase() == 'authorization') {
        request.headers.set(info.authHeader, '${info.authPrefix}reachability-probe');
      } else {
        request.headers.set(info.authHeader, 'reachability-probe');
      }
      request.add(utf8.encode(info.style == ConnectorStyle.gemini
          ? jsonEncode(<String, dynamic>{
              'contents': [
                {
                  'role': 'user',
                  'parts': [
                    {'text': 'ping'}
                  ]
                }
              ]
            })
          : jsonEncode(<String, dynamic>{
              'model': model,
              'messages': [
                {'role': 'user', 'content': 'ping'}
              ],
              'max_tokens': 1,
            })));

      final response = await request
          .close()
          .timeout(const Duration(seconds: 20));
      final body = await response.transform(utf8.decoder).join();
      final latency = DateTime.now().difference(started).inMilliseconds;

      // 401/403 = وصلنا للخادم ورفض المفتاح → الشبكة سليمة
      final reachable = response.statusCode == 401 ||
          response.statusCode == 403 ||
          response.statusCode == 200 ||
          response.statusCode == 400 ||
          response.statusCode == 429;

      return ConnectorTestResult(
        ok: reachable,
        statusCode: response.statusCode,
        latencyMs: latency,
        providerLabel: info.label,
        endpoint: _resolvedEndpoint(info),
        model: model,
        errorText: reachable
            ? (response.statusCode == 401 || response.statusCode == 403
                ? 'الشبكة والـ endpoint سليمين — الرمز ${response.statusCode} '
                    'يعني أن المفتاح هو المطلوب ضبطه'
                : null)
            : _extractProviderError(body, response.statusCode),
      );
    } on SocketException catch (e) {
      return ConnectorTestResult(
        ok: false,
        statusCode: 0,
        latencyMs: DateTime.now().difference(started).inMilliseconds,
        providerLabel: info.label,
        endpoint: _resolvedEndpoint(info),
        model: model,
        errorText: 'تعذّر الوصول للخادم (${e.osError?.message ?? e.message}) — '
            'تحقق من الإنترنت أو من صحة الـ endpoint',
      );
    } on TimeoutException {
      return ConnectorTestResult(
        ok: false,
        statusCode: 0,
        latencyMs: DateTime.now().difference(started).inMilliseconds,
        providerLabel: info.label,
        endpoint: _resolvedEndpoint(info),
        model: model,
        errorText: 'انتهت المهلة قبل رد الخادم — الشبكة بطيئة أو الـ endpoint محجوب',
      );
    } on HandshakeException catch (e) {
      return ConnectorTestResult(
        ok: false,
        statusCode: 0,
        latencyMs: DateTime.now().difference(started).inMilliseconds,
        providerLabel: info.label,
        endpoint: _resolvedEndpoint(info),
        model: model,
        errorText: 'فشل TLS: ${e.message}',
      );
    } catch (e) {
      return ConnectorTestResult(
        ok: false,
        statusCode: 0,
        latencyMs: DateTime.now().difference(started).inMilliseconds,
        providerLabel: info.label,
        endpoint: _resolvedEndpoint(info),
        model: model,
        errorText: e.toString(),
      );
    } finally {
      client.close(force: true);
      providerId = savedProvider;
      endpoint = savedEndpoint;
      model = savedModel;
    }
  }

  static Map<String, dynamic>? _decodeLooseJson(String raw) {
    var cleaned = raw.trim();
    cleaned = cleaned.replaceAll(RegExp(r'^```(?:json)?\s*'), '');
    cleaned = cleaned.replaceAll(RegExp(r'\s*```$'), '');
    try {
      final decoded = jsonDecode(cleaned);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }
}
