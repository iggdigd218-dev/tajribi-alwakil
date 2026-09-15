import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show MethodChannel, PlatformException;

import '../models/agent_action_intent.dart';

/// ناتج معالجة أمر صوتي عبر Gemini.
class GeminiVoiceOutcome {
  const GeminiVoiceOutcome({
    required this.reply,
    required this.actions,
    this.error,
  });

  /// الرد اللغوي القصير (يُنطق صوتياً).
  final String reply;

  /// الأوامر التنفيذية المستخرجة (جاهزة للمفرّق المركزي).
  final List<AgentActionIntent> actions;

  /// رسالة خطأ إن فشل الطلب (مفتاح/اتصال/صياغة).
  final String? error;

  bool get hasError => error != null;
}

/// عميل Gemini API النقي (المرحلة 5).
///
/// - يعتمد حصراً على dart:io HttpClient — صفر تبعيات خارجية.
/// - المفتاح يُقرأ من `--dart-define=GEMINI_API_KEY=...` أو يُمرَّر
///   برمجياً عبر [apiKey] (التمرير البرمجي يتقدم على dart-define).
/// - [processVoiceCommand]: يحوّل الكلام إلى {رد قصير + أوامر تنفيذية}
///   وفق شخصية المساعد الرجالي الوقور سريع البديهة.
class GeminiService {
  GeminiService._();

  /// مفتاح برمجي اختياري (يتقدم على --dart-define).
  static String? _programmaticKey;

  /// مفتاح Gemini الفعّال.
  static String get apiKey =>
      _programmaticKey ?? const String.fromEnvironment('GEMINI_API_KEY');

  /// تمرير المفتاح برمجياً (فارغ أو null = الرجوع لـ dart-define).
  static set apiKey(String? value) => _programmaticKey =
      (value == null || value.trim().isEmpty) ? null : value.trim();

  /// هل المفتاح مضبوط؟
  static bool get isConfigured => apiKey.isNotEmpty;

  /// اسم الموديل القياسي (gemini-2.0-flash يسبب 404 على v1beta لبعض المفاتيح).
  static String model = 'gemini-1.5-flash';

  static const Duration _timeout = Duration(seconds: 25);

  // ═══════════════════════════════════════════
  //  التخزين المحلي الآمن للمفتاح (المرحلة 5b)
  //  SharedPreferences أصلياً عبر جسر AppSettingsBridge
  // ═══════════════════════════════════════════

  /// قناة الإعدادات — قراءة/كتابة المفتاح عبر الطبقة الأصلية.
  static const MethodChannel _settingsChannel =
      MethodChannel('com.example.app/settings');

  /// تحميل المفتاح المحفوظ في SharedPreferences عند تشغيل التطبيق
  /// وتعيينه برمجياً (المفتاح المحفوظ يتقدم على --dart-define).
  static Future<void> loadSavedKey() async {
    try {
      final saved =
          await _settingsChannel.invokeMethod<String>('getGeminiApiKey');
      if (saved != null && saved.trim().isNotEmpty) {
        _programmaticKey = saved.trim();
      }
    } on PlatformException {
      // القناة غير جاهزة — يبقى مفتاح dart-define (إن وُجد)
    }
  }

  /// حفظ المفتاح في SharedPreferences تحت "gemini_api_key"
  /// وتفعيله فوراً لهذه الجلسة.
  static Future<bool> saveApiKey(String key) async {
    final clean = key.trim();
    if (clean.isEmpty) return false;
    try {
      final ok = await _settingsChannel
              .invokeMethod<bool>('setGeminiApiKey', {'key': clean}) ??
          false;
      if (ok) _programmaticKey = clean;
      return ok;
    } on PlatformException {
      return false;
    }
  }

  /// حذف المفتاح المخزن والعودة لمفتاح dart-define (إن وُجد).
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

  /// تعليمات النظام: الشخصية الرجالية + عقد JSON للأوامر التنفيذية.
  static const String _voiceSystemPrompt = '''
أنت "الوكيل": مساعد شخصي ذكر، وقور، سريع البديهة، ومحترم.
تتحاور بالعربية الفصحى المبسطة بنبرة رصينة هادئة تناسب الرد الصوتي.

قواعد صارمة:
1. حقل reply جملة أو جملتان قصيرتان كحد أقصى — سيُنطق صوتياً فوراً.
2. ممنوع في reply: الرموز، النجوم، الجداول، الأكواد، الإيموجي.
3. حوار عام بلا طلب تنفيذي → اجعل actions مصفوفة فارغة.
4. طلب تنفيذي (شبكة/اتصال/تطبيق/دفع/جدولة/أمر نظام) → املأ actions.
5. requiresConfirmation = true فقط للعمليات المالية.
6. slotIndex مبني على الصفر: الشريحة الأولى 0، الثانية 1.
7. scheduledTime بصيغة ISO8601 للطلبات المؤجلة ("بعد 5 دقائق"، "الساعة 9 مساءً")، وإلا null.

أعد دائماً JSON صالحاً فقط بهذه البنية:
{
  "reply": "رد قصير للنطق",
  "actions": [
    {
      "actionType": "toggle_wifi | toggle_mobile_data | open_app | call | shell_command | input_tap | input_text | ui_click | ui_set_text | payment",
      "category": "system | automation | scheduler | payment | call",
      "targetApp": "اسم التطبيق أو null",
      "parameters": { "enable": true, "phoneNumber": "712345678", "slotIndex": 1, "appName": "واتساب", "amount": 5000, "command": "..." },
      "scheduledTime": null,
      "requiresConfirmation": false
    }
  ]
}

أمثلة:
"صباح الخير" → {"reply":"صباح النور والبركة، كيف حالك اليوم؟","actions":[]}
"اطفئ النت بعد ربع ساعة" → {"reply":"حسناً، سأطفئ بيانات الجوال بعد ربع ساعة.","actions":[{"actionType":"toggle_mobile_data","category":"system","targetApp":null,"parameters":{"enable":false},"scheduledTime":"<بعد 15 دقيقة بصيغة ISO8601>","requiresConfirmation":false}]}
"حول خمسة آلاف من محفظة جوادي" → {"reply":"هذه عملية مالية وسأحتاج تأكيدك على الشاشة.","actions":[{"actionType":"payment","category":"payment","targetApp":"جوادي","parameters":{"walletName":"جوادي","amount":5000},"scheduledTime":null,"requiresConfirmation":true}]}
''';

  /// معالجة أمر صوتي: رد قصير + أوامر تنفيذية جاهزة للمفرّق.
  ///
  /// [history] محادثة سابقة اختيارية بصيغة
  /// `[{'role': 'user'|'model', 'text': '...'}]` للاستمرارية الحوارية.
  static Future<GeminiVoiceOutcome> processVoiceCommand(
    String userText, {
    List<Map<String, Object?>>? history,
  }) async {
    if (!isConfigured) {
      return const GeminiVoiceOutcome(
        reply: '',
        actions: [],
        error: 'مفتاح GEMINI_API_KEY غير مضبوط',
      );
    }
    if (userText.trim().isEmpty) {
      return const GeminiVoiceOutcome(reply: '', actions: [], error: 'نص فارغ');
    }

    try {
      final data = await _generate(
        userText: userText,
        systemPrompt: _voiceSystemPrompt,
        forceJson: true,
        temperature: 0.2,
        history: history,
      );
      if (data == null) {
        return const GeminiVoiceOutcome(
          reply: '',
          actions: [],
          error: 'استجابة فارغة من الخدمة',
        );
      }

      final raw = _extractText(data);
      if (raw == null || raw.trim().isEmpty) {
        return const GeminiVoiceOutcome(
          reply: '',
          actions: [],
          error: 'لم يرجع النموذج نصاً',
        );
      }

      final map = _decodeLooseJson(raw);
      if (map == null) {
        // رد غير مهيكل — نعتبره رداً لغوياً صالحاً للنطق بلا خطأ
        return GeminiVoiceOutcome(reply: raw.trim(), actions: const []);
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
            actions.add(AgentActionIntent.fromJson(json));
          }
        }
      }
      return GeminiVoiceOutcome(reply: reply, actions: actions);
    } on SocketException {
      return const GeminiVoiceOutcome(
        reply: '',
        actions: [],
        error: 'لا اتصال بالإنترنت',
      );
    } on HttpException catch (e) {
      return GeminiVoiceOutcome(
        reply: '',
        actions: const [],
        error: 'خطأ HTTP من Gemini: ${e.message}',
      );
    } catch (e) {
      return GeminiVoiceOutcome(reply: '', actions: const [], error: e.toString());
    }
  }

  // ═══════════════════════════════════════════
  //  نواة REST — HttpClient النقي من dart:io
  // ═══════════════════════════════════════════

  static Future<Map<String, dynamic>?> _generate({
    required String userText,
    required String systemPrompt,
    required bool forceJson,
    required double temperature,
    List<Map<String, Object?>>? history,
  }) async {
    final uri = Uri.parse(
      'https://generativelanguage.googleapis.com/v1beta/models/'
      '$model:generateContent?key=$apiKey',
    );

    final contents = <Map<String, dynamic>>[
      if (history != null)
        for (final entry in history)
          {
            'role': entry['role'] as String? ?? 'user',
            'parts': [
              {'text': entry['text'] as String? ?? ''}
            ],
          },
      {
        'role': 'user',
        'parts': [
          {'text': userText}
        ],
      },
    ];

    final body = jsonEncode(<String, dynamic>{
      'system_instruction': {
        'parts': [
          {'text': systemPrompt}
        ]
      },
      'contents': contents,
      'generationConfig': {
        'temperature': temperature,
        'maxOutputTokens': 1024,
        if (forceJson) 'responseMimeType': 'application/json',
      },
    });

    final client = HttpClient()..connectionTimeout = _timeout;
    try {
      final request = await client.postUrl(uri).timeout(_timeout);
      request.headers.contentType =
          ContentType('application', 'json', charset: 'utf-8');
      // إرسال البايتات مباشرة حتى لا تتشوّه الحروف العربية داخل الـ prompt
      request.add(utf8.encode(body));
      final response = await request.close().timeout(_timeout);
      final responseBody = await response.transform(utf8.decoder).join();

      if (response.statusCode != 200) {
        final snippet = responseBody.length > 800
            ? responseBody.substring(0, 800)
            : responseBody;
        throw HttpException('HTTP ${response.statusCode}: $snippet');
      }
      return jsonDecode(responseBody) as Map<String, dynamic>;
    } finally {
      client.close();
    }
  }

  /// استخراج نص الرد من الاستجابة القياسية للـ API.
  static String? _extractText(Map<String, dynamic> data) {
    final candidates = data['candidates'];
    if (candidates is! List || candidates.isEmpty) return null;
    final content = (candidates[0] as Map?)?['content'];
    final parts = (content as Map?)?['parts'];
    if (parts is! List || parts.isEmpty) return null;
    return (parts[0] as Map?)?['text'] as String?;
  }

  /// فك JSON مع تنظيف أسوار الأكواد إن وُجدت.
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
