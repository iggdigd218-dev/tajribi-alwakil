import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:flutter/services.dart';

import '../models/agent_action_intent.dart';
import 'agent_dispatcher.dart';
import 'gemini_service.dart';
import 'edge_tts_service.dart';
import 'elevenlabs_tts_service.dart';
import 'intent_parser_service.dart';
import 'offline_assistant.dart';

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

  /// تفعيل/تعطيل الصوت العصبي (ElevenLabs/Edge TTS). الافتراضي: مفعّل.
  static bool neuralVoiceEnabled = true;

  /// آخر محرك نطق استُخدم فعلياً: 'neural' أو 'system'.
  static String lastSpeechEngine = 'none';

  /// يُستدعى عند التراجع الاضطراري لمحرك النظام — تعرضه الواجهة
  /// للمستخدم مع السبب حتى نُشخّص شبكته/جهازه بدقة.
  static void Function(String reason)? onNeuralFallback;

  /// نطق نص بصوت الوكيل الرجالي.
  ///
  /// سلسلة النطق: ElevenLabs (المفتاح المدمج، multilingual v2) ←
  /// Edge TTS العصبي المجاني (ar-SA-HamedNeural) ← محرك النظام المحلي.
  /// التراجع تلقائي وفوري عند أي فشل فلا ينقطع الكلام أبداً، ويُعرض
  /// سبب التراجع للمستخدم عبر onNeuralFallback.
  static Future<void> speak(String text) async {
    if (text.trim().isEmpty) return;

    // 1) الأصوات العصبية (AI): ElevenLabs أولاً ثم Edge TTS المجاني
    if (neuralVoiceEnabled) {
      String? path;
      var engine = 'neural';
      try {
        if (ElevenLabsTtsService.isConfigured) {
          path = await ElevenLabsTtsService.synthesize(text);
          if (path != null) engine = 'elevenlabs';
        }
        if (path == null) {
          path = await EdgeTtsService.synthesize(text);
        }
        if (path != null) {
          final ok = await _channel.invokeMethod<bool>('playAudioFile', path) ??
              false;
          if (ok) {
            lastSpeechEngine = engine;
            return;
          }
          EdgeTtsService.lastError ??= 'رفض المشغّل الأصلي الملف';
        }
      } on PlatformException {
        EdgeTtsService.lastError ??= 'قناة الصوت الأصلي غير جاهزة';
      }
    }

    // 2) الارتداد: محرك النظام المحلي
    lastSpeechEngine = 'system';
    final reasons = <String>[
      if (ElevenLabsTtsService.isConfigured &&
          ElevenLabsTtsService.lastError != null)
        ElevenLabsTtsService.lastError!,
      if (EdgeTtsService.lastError != null) EdgeTtsService.lastError!,
    ];
    final reason = reasons.isEmpty ? 'تعذر التوليد العصبي' : reasons.join(' | ');
    onNeuralFallback?.call(reason);
    try {
      await _channel.invokeMethod<void>('speakText', text);
    } on PlatformException {
      // تجاهل صامت — النطق غير متاح
    }
  }

  /// إيقاف الكلام الجاري فوراً (العصبي والنظامي معاً).
  static Future<void> stopSpeaking() async {
    try {
      await _channel.invokeMethod<void>('stopAudioPlayback');
    } on PlatformException {
      // تجاهل صامت
    }
  }

  // ═══════════════════════════════════════════
  //  الدورة الصوتية الكاملة
  // ═══════════════════════════════════════════

  static Future<void> _processVoiceCommand(String rawCommand) async {
    // منع تداخل أمرين صوتيين أثناء المعالجة
    if (_processing) return;
    _processing = true;
    try {
      // ── 0) طبقة إعادة الصياغة بالذكاء: نص الاستماع الصوتي كثير
      // الأخطاء — يُمرر للـ AI ليصوغه أمراً واضحاً قبل التحليل، فلا
      // يضطر المستخدم لتكرار طلبه. (بلا موصل = النص كما هو)
      var command = rawCommand;
      var intent = await IntentParserService.parseLocalAsync(command);
      if (intent == null) {
        final reform = await GeminiService.reformulateCommand(rawCommand);
        if (reform != null) {
          command = reform;
          intent = await IntentParserService.parseLocalAsync(command);
        }
      }
      // ── 1) المسار السريع: محلل محلي فوري دون إنترنت ──
      if (intent != null) {
        final result = await AgentDispatcher.execute(intent);
        await _speakResult(result);
        onVoiceCommandExecuted?.call(command, intent, result);
        return;
      }

      // ── 2) الدماغ المحلي: معرفة الجهاز + الحوار العام ──
      // يُجرَّب قبل السحابة لأن إجاباته فورية ومجانية وموثوقة
      // (البطارية، التطبيقات المثبتة، التحية، الوقت، الحساب).
      final offline = await OfflineAssistant.respond(command);
      if (offline.match != OfflineMatch.none) {
        await speak(offline.reply);
        onAssistantReply?.call(offline.displayText);
        for (final a in offline.actions) {
          final r = await AgentDispatcher.execute(a);
          onVoiceCommandExecuted?.call(command, a, r);
        }
        return;
      }

      // ── 3) المسار الذكي: حوار حر أو أمر مركب عبر الموصل ──
      if (!GeminiService.isConfigured) {
        // لا يوجد موصل — الدماغ المحلي هو الرد النهائي، بصوت طبيعي
        final message = offline.reply.isEmpty
            ? 'لم أفهم هذا الأمر. اسألني «ماذا تستطيع؟» لأشرح لك.'
            : offline.reply;
        await speak(message);
        onAssistantReply?.call(offline.displayText);
        return;
      }

      final outcome = await GeminiService.processVoiceCommand(command);

      if (outcome.hasError) {
        // فشل الموصل لا يُنهي المحادثة — نتحول للدماغ المحلي
        final recovered = await OfflineAssistant.recoverFromConnectorFailure(
          command,
          outcome.error,
          statusCode: outcome.statusCode,
        );
        // صوتياً نختصر: ننطق الرد المحلي ونذكر العطل بجملة واحدة
        final spoken = recovered.match != OfflineMatch.none
            ? recovered.reply
            : '${OfflineAssistant.classifyError(outcome.error, statusCode: outcome.statusCode).arabic}. '
                'الأوامر التنفيذية تعمل دون إنترنت.';
        await speak(spoken);
        onAssistantReply?.call(recovered.displayText);
        for (final a in recovered.actions) {
          final r = await AgentDispatcher.execute(a);
          onVoiceCommandExecuted?.call(command, a, r);
        }
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
      AgentDispatchStatus.degraded =>
        'نفذت ما أقدر عليه، وأكملت الباقي على الشاشة.',
      AgentDispatchStatus.unknownCommand => 'أمر غير معروف.',
    };
    await speak(phrase);
  }
}
