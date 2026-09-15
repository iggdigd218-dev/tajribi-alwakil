import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:flutter/services.dart';

import '../models/agent_action_intent.dart';
import 'agent_dispatcher.dart';
import 'gemini_service.dart';
import 'intent_parser_service.dart';

/// الدورة الصوتية الكاملة (المرحلة 5) — الوجه الدارتي لمحرك الصوت.
///
/// يربط القناة الأصلية "com.example.app/voice" بالمنطق الذكي:
///
///  1. يستقبل onWakeWordTriggered من VoiceManager (النص بعد اقتطاع
///     اسم النداء).
///  2. المسار السريع: IntentParserService المحلي (دون إنترنت) →
///     AgentDispatcher → نطق تأكيد صوتي قصير.
///  3. المسار الذكي: أوامر حوارية/مركبة → GeminiService → نطق الرد
///     وتنفيذ الأوامر المرفقة (مع بوابة التأكيد الأمني للمالية).
class VoiceService {
  VoiceService._();

  static const MethodChannel _channel = MethodChannel('com.example.app/voice');

  /// حالة الاستماع الدائم — للربط مع الواجهة.
  static final ValueNotifier<bool> isListening = ValueNotifier<bool>(false);

  /// اسم الوكيل الحالي (Wake-Word) — للعرض والتعديل من الواجهة.
  static final ValueNotifier<String> wakeWord = ValueNotifier<String>('يا وكيل');

  /// تُنبَّه الواجهة عند تنفيذ أمر صوتي (لإضافته كبطاقة في الشات).
  /// تحمل: نص الأمر، النية المنفذة، ونتيجة التنفيذ.
  static void Function(String command, AgentActionIntent intent, AgentDispatchResult result)?
      onVoiceCommandExecuted;

  /// تُنبَّه الواجهة عند رد الوكيل اللغوي (ليُعرض في الشات).
  static void Function(String reply)? onAssistantReply;

  static bool _initialized = false;
  static bool _processing = false;

  // ═══════════════════════════════════════════
  //  التهيئة
  // ═══════════════════════════════════════════

  /// تهيئة الدورة الصوتية — تُستدعى مرة عند فتح شاشة الشات.
  static Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    // المرحلة 5b: تحميل مفتاح Gemini المحفوظ محلياً (SharedPreferences)
    // ليعمل المسار السحابي في حلقة الصوت مباشرة دون إعادة الإدخال.
    await GeminiService.loadSavedKey();

    _channel.setMethodCallHandler(_handleNativeCall);

    try {
      final name = await _channel.invokeMethod<String>('getWakeWord');
      if (name != null && name.trim().isNotEmpty) {
        wakeWord.value = name.trim();
      }
      isListening.value =
          await _channel.invokeMethod<bool>('isListening') ?? false;
    } on PlatformException {
      // المحرك غير جاهز بعد — تُترك القيم الافتراضية
    }
  }

  static Future<dynamic> _handleNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'onWakeWordTriggered':
        final command = call.arguments as String? ?? '';
        if (command.trim().isNotEmpty) {
          await _processVoiceCommand(command.trim());
        }
        return null;

      case 'onListeningStateChanged':
        isListening.value = call.arguments as bool? ?? false;
        return null;

      case 'onVoiceError':
        onAssistantReply?.call('⚠️ ${call.arguments ?? 'خطأ صوتي غير معروف'}');
        return null;
    }
  }

  // ═══════════════════════════════════════════
  //  التحكم العام
  // ═══════════════════════════════════════════

  /// بدء الاستماع الدائم (يطلب صلاحية الميكروفون تلقائياً عند الحاجة).
  static Future<bool> startListening() async {
    try {
      final granted =
          await _channel.invokeMethod<bool>('hasRecordAudioPermission') ?? false;
      if (!granted) {
        final ok =
            await _channel.invokeMethod<bool>('requestRecordAudioPermission') ??
                false;
        if (!ok) return false;
      }
      final started =
          await _channel.invokeMethod<bool>('startContinuousListening') ?? false;
      if (started) isListening.value = true;
      return started;
    } on PlatformException {
      return false;
    }
  }

  /// إيقاف الاستماع الدائم.
  static Future<bool> stopListening() async {
    try {
      final stopped = await _channel.invokeMethod<bool>('stopListening') ?? false;
      if (stopped) isListening.value = false;
      return stopped;
    } on PlatformException {
      return false;
    }
  }

  /// حفظ اسم الوكيل (كلمة النداء) — يُخزَّن في SharedPreferences أصلياً.
  static Future<bool> setWakeWord(String name) async {
    final clean = name.trim();
    if (clean.isEmpty) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('setWakeWord', {
            'name': clean,
          }) ??
          false;
      if (ok) wakeWord.value = clean;
      return ok;
    } on PlatformException {
      return false;
    }
  }

  /// نطق نص بصوت الوكيل الرجالي.
  static Future<void> speak(String text) async {
    if (text.trim().isEmpty) return;
    try {
      await _channel.invokeMethod<void>('speakText', text);
    } on PlatformException {
      // تجاهل صامت — النطق غير متاح
    }
  }

  // ═══════════════════════════════════════════
  //  الدورة الصوتية الكاملة
  // ═══════════════════════════════════════════

  static Future<void> _processVoiceCommand(String command) async {
    // منع تداخل أمرين صوتيين أثناء المعالجة
    if (_processing) return;
    _processing = true;
    try {
      // ── 1) المسار السريع: محلل محلي فوري دون إنترنت ──
      final intent = IntentParserService.parse(command);
      if (intent != null) {
        final result = await AgentDispatcher.execute(intent);
        await _speakResult(result);
        onVoiceCommandExecuted?.call(command, intent, result);
        return;
      }

      // ── 2) المسار الذكي: حوار أو أمر مركب عبر Gemini ──
      if (!GeminiService.isConfigured) {
        const message =
            'هذا أمر مركب يحتاج محرك التفكير السحابي، والمفتاح غير مضبوط بعد.';
        await speak(message);
        onAssistantReply?.call(message);
        return;
      }

      final outcome = await GeminiService.processVoiceCommand(command);

      if (outcome.hasError) {
        await speak('تعذر الاتصال بمحرك التفكير السحابي.');
        onAssistantReply?.call('⚠️ ${outcome.error}');
        return;
      }

      // نطق الرد اللغوي فوراً
      if (outcome.reply.isNotEmpty) {
        await speak(outcome.reply);
        onAssistantReply?.call(outcome.reply);
      } else if (outcome.actions.isNotEmpty) {
        await speak('حسناً، سأنفذ الأمر الآن.');
      }

      // تنفيذ الأوامر المرفقة — لا نكرر النطق لكل أمر إن كان الرد
      // اللغوي كافياً، إلا عند الفشل أو الحاجة للتأكيد الأمني.
      for (final actionIntent in outcome.actions) {
        final result = await AgentDispatcher.execute(actionIntent);
        if (result.status == AgentDispatchStatus.needsConfirmation) {
          await speak('هذه عملية مالية وتتطلب تأكيدك على الشاشة.');
        } else if (result.status == AgentDispatchStatus.failed) {
          await speak('تعذر تنفيذ أحد الأوامر.');
        }
        onVoiceCommandExecuted?.call(command, actionIntent, result);
      }
    } finally {
      _processing = false;
    }
  }

  /// تحويل نتيجة التنفيذ إلى جملة تأكيد صوتية قصيرة.
  static Future<void> _speakResult(AgentDispatchResult result) async {
    final phrase = switch (result.status) {
      AgentDispatchStatus.executed => result.message, // مثل: تم تفعيل الواي فاي
      AgentDispatchStatus.scheduled => 'تمت جدولة المهمة بنجاح.',
      AgentDispatchStatus.needsConfirmation =>
        'هذه عملية مالية وتتطلب تأكيدك على الشاشة.',
      AgentDispatchStatus.failed => 'تعذر تنفيذ الأمر.',
      AgentDispatchStatus.unknownCommand => 'أمر غير معروف.',
    };
    await speak(phrase);
  }
}
