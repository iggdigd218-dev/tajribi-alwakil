import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show MethodChannel, PlatformException;

import '../models/agent_action_intent.dart';

/// مزود OpenAI-compatible.
class AiProviderInfo {
  const AiProviderInfo({
    required this.id,
    required this.label,
    required this.endpoint,
    required this.defaultModel,
  });

  final String id;
  final String label;
  final String endpoint;
  final String defaultModel;
}

/// ناتج معالجة أمر عبر المحرك السحابي.
class GeminiVoiceOutcome {
  const GeminiVoiceOutcome({
    required this.reply,
    required this.actions,
    this.error,
  });

  final String reply;
  final List<AgentActionIntent> actions;
  final String? error;

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

  static const List<AiProviderInfo> providers = [
    AiProviderInfo(
      id: 'groq',
      label: 'Groq',
      endpoint: 'https://api.groq.com/openai/v1/chat/completions',
      defaultModel: 'llama-3.3-70b-versatile',
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

  static String providerId = 'groq';
  static String endpoint =
      'https://api.groq.com/openai/v1/chat/completions';
  static String model = 'llama-3.3-70b-versatile';
  static String? _programmaticKey;

  static String get apiKey =>
      _programmaticKey ?? const String.fromEnvironment('GEMINI_API_KEY');

  static set apiKey(String? value) => _programmaticKey =
      (value == null || value.trim().isEmpty) ? null : value.trim();

  static bool get isConfigured =>
      apiKey.isNotEmpty && endpoint.trim().isNotEmpty && model.trim().isNotEmpty;

  static String get providerLabel => byId(providerId).label;

  static const String _systemPrompt = '''
أنت "الوكيل": مساعد شخصي ذكر، وقور، سريع البديهة، ومحترم.
تتحاور بالعربية الفصحى المبسطة بنبرة رصينة هادئة تناسب الرد الصوتي.
أنت مساعد ذكي للأتمتة والتحكم بالنظام باللغة العربية. إذا طلب المستخدم أمراً تنفيذياً (واي فاي، بيانات، فتح تطبيق، اتصال)، أعد JSON بالأمر التنفيذي، وإلا فرد حوارياً باقتضاب.

قواعد صارمة:
1. حقل reply جملة أو جملتان قصيرتان كحد أقصى — سيُنطق صوتياً فوراً.
2. ممنوع في reply: الرموز، النجوم، الجداول، الأكواد، الإيموجي.
3. حوار عام بلا طلب تنفيذي → اجعل actions مصفوفة فارغة.
4. طلب تنفيذي (شبكة/اتصال/تطبيق/دفع/جدولة/أمر نظام) → املأ actions.
5. requiresConfirmation = true فقط للعمليات المالية.
6. slotIndex مبني على الصفر: الشريحة الأولى 0، الثانية 1.
7. scheduledTime بصيغة ISO8601 للطلبات المؤجلة، وإلا null.

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
"الووو" → {"reply":"وعليكم السلام، تفضل أمرك.","actions":[]}
"اطفئ النت بعد ربع ساعة" → {"reply":"حسناً، سأطفئ بيانات الجوال بعد ربع ساعة.","actions":[{"actionType":"toggle_mobile_data","category":"system","targetApp":null,"parameters":{"enable":false},"scheduledTime":null,"requiresConfirmation":false}]}
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
      );
    }
    if (userText.trim().isEmpty) {
      return const GeminiVoiceOutcome(reply: '', actions: [], error: 'نص فارغ');
    }

    try {
      final raw = await _chatCompletions(
        userText: userText,
        history: history,
      );
      if (raw == null || raw.trim().isEmpty) {
        return const GeminiVoiceOutcome(
          reply: '',
          actions: [],
          error: 'لم يرجع النموذج نصاً',
        );
      }

      final map = _decodeLooseJson(raw);
      if (map == null) {
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
      return GeminiVoiceOutcome(
        reply: reply.isEmpty ? raw.trim() : reply,
        actions: actions,
      );
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
        error: 'خطأ HTTP من ${providerLabel}: ${e.message}',
      );
    } catch (e) {
      return GeminiVoiceOutcome(
        reply: '',
        actions: const [],
        error: e.toString(),
      );
    }
  }

  static Future<String?> _chatCompletions({
    required String userText,
    List<Map<String, Object?>>? history,
  }) async {
    final uri = Uri.parse(endpoint);
    final messages = <Map<String, dynamic>>[
      {'role': 'system', 'content': _systemPrompt},
      if (history != null)
        for (final entry in history)
          {
            'role': entry['role'] as String? ?? 'user',
            'content': entry['text'] as String? ?? '',
          },
      {'role': 'user', 'content': userText},
    ];

    final body = jsonEncode(<String, dynamic>{
      'model': model,
      'messages': messages,
      'temperature': 0.3,
    });

    final client = HttpClient()..connectionTimeout = _timeout;
    try {
      final request = await client.postUrl(uri).timeout(_timeout);
      request.headers.set(
        HttpHeaders.contentTypeHeader,
        'application/json; charset=utf-8',
      );
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $apiKey');
      request.headers.set('HTTP-Referer', 'https://agent-automation.local');
      request.headers.set('X-Title', 'Agent Automation');
      request.add(utf8.encode(body));

      final response = await request.close().timeout(_timeout);
      final responseBody = await response.transform(utf8.decoder).join();

      if (response.statusCode != 200) {
        final snippet = responseBody.length > 800
            ? responseBody.substring(0, 800)
            : responseBody;
        throw HttpException('HTTP ${response.statusCode}: $snippet');
      }

      final data = jsonDecode(responseBody);
      if (data is! Map<String, dynamic>) return null;
      final choices = data['choices'];
      if (choices is! List || choices.isEmpty) return null;
      final message = (choices[0] as Map?)?['message'];
      return (message as Map?)?['content'] as String?;
    } finally {
      client.close();
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
