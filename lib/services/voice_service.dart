import 'dart:io';
import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:flutter/services.dart';

import '../models/agent_action_intent.dart';
import 'agent_dispatcher.dart';
import 'gemini_service.dart';
import 'edge_tts_service.dart';
import 'elevenlabs_tts_service.dart';
import 'voice_profiles.dart';
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
  static final ValueNotifier<String> wakeWord = ValueNotifier<String>('حمود');

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
    await loadVoiceProfile();

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

  /// نمط الصوت الرجالي المختار من الإعدادات (الخمس أنماط).
  static String _profileId = 'calm';
  static VoiceProfile get voiceProfile => VoiceProfile.byId(_profileId);

  /// قراءة النمط المحفوظ أصلياً من تفضيلات التطبيق.
  static Future<void> loadVoiceProfile() async {
    try {
      final id = await _channel.invokeMethod<String>('getVoiceProfile');
      if (id != null && id.trim().isNotEmpty) _profileId = id.trim();
    } on PlatformException {
      // يُترك الافتراضي
    }
  }

  /// حفظ نمط الصوت — يعود false إن رفضت القناة الأصلية.
  static Future<bool> setVoiceProfile(String id) async {
    if (VoiceProfile.byId(id).id != id) return false;
    try {
      final ok =
          await _channel.invokeMethod<bool>('setVoiceProfile', {'id': id}) ??
              false;
      if (ok) _profileId = id;
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
        final profile = voiceProfile;
        if (ElevenLabsTtsService.isConfigured) {
          path = await ElevenLabsTtsService.synthesize(text);
          if (path != null) engine = 'elevenlabs';
        }
        if (path == null) {
          path = await EdgeTtsService.synthesize(text, voice: profile.edgeVoice);
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

  /// نطق عينة صوتية بنمط محدّد (للمعاينة في الإعدادات) — لا يغيّر
  /// النمط المحفوظ: يولّد بصوت النمط المطلوب ويشغّله فوراً.
  static Future<void> speakSample(String text, VoiceProfile profile) async {
    final clean = text.trim();
    if (clean.isEmpty) return;
    await stopSpeaking();
    // 1) العينة المدمجة داخل التطبيق — فورية وتعمل دون إنترنت،
    //    وتُسمع النبرة الحقيقية لكل نمط كما هي تماماً.
    try {
      final data = await rootBundle.load('assets/voice_samples/${profile.id}.mp3');
      final sample = File('${Directory.systemTemp.path}/sample_${profile.id}.mp3');
      await sample.writeAsBytes(data.buffer.asUint8List(), flush: true);
      final played =
          await _channel.invokeMethod<bool>('playAudioFile', sample.path) ??
              false;
      if (played) return;
    } catch (_) {
      // نتحول للتوليد الحي
    }
    // 2) توليد حي بصوت النمط (Edge / ElevenLabs)
    String? path;
    try {
      if (ElevenLabsTtsService.isConfigured) {
        path = await ElevenLabsTtsService.synthesize(clean);
      }
      path ??= await EdgeTtsService.synthesize(clean, voice: profile.edgeVoice);
      if (path != null) {
        final ok =
            await _channel.invokeMethod<bool>('playAudioFile', path) ?? false;
        if (ok) return;
      }
    } on PlatformException {
      // نتحول لمحرك النظام
    }
    try {
      await _channel.invokeMethod<void>('speakText', clean);
    } on PlatformException {
      // النطق غير متاح
    }
  }

  /// لقطة تشخيصية حيّة لسلسلة الاستماع بالخلفية (لكشف أين تنكسر).
  static Future<String> listeningDiagnostics() async {
    try {
      return await _channel.invokeMethod<String>('getListeningDiagnostics') ??
          'التشخيص غير متاح';
    } on PlatformException {
      return 'التشخيص غير متاح';
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

      // ── 1) الذكاء السحابي هو المستمع الأول (طلب المستخدم): يستقبل
      // الطلب الخام كما نطقه المستخدم، يصيغ الأمر الواضح، والوكيل ينفذه.
      GeminiVoiceOutcome? cloud;
      if (GeminiService.isConfigured) {
        cloud = await GeminiService.processVoiceCommand(command);
        if (!cloud.hasError ||
            cloud.reply.isNotEmpty ||
            cloud.actions.isNotEmpty) {
          final reply = cloud.reply;
          final actions = cloud.actions;
          if (reply.isNotEmpty) {
            await speak(reply);
            onAssistantReply?.call(reply);
          } else if (actions.isNotEmpty) {
            await speak('حسناً، سأنفذ الأمر الآن.');
          }
          for (final actionIntent in actions) {
            final result = await AgentDispatcher.execute(actionIntent);
            if (result.status == AgentDispatchStatus.needsConfirmation) {
              await speak('هذه عملية مالية وتتطلب تأكيدك على الشاشة.');
            } else if (result.status == AgentDispatchStatus.failed) {
              await speak('تعذر تنفيذ أحد الأوامر.');
            }
            onVoiceCommandExecuted?.call(command, actionIntent, result);
          }
          return;
        }
      }

      // ── 2) المسار المحلي السريع (عند غياب الموصل أو تعذّره) ──
      var intent = await IntentParserService.parseLocalAsync(command);
      if (intent == null) {
        final reform = await GeminiService.reformulateCommand(command);
        if (reform != null) {
          command = reform;
          intent = await IntentParserService.parseLocalAsync(command);
        }
      }
      if (intent != null) {
        final result = await AgentDispatcher.execute(intent);
        await _speakResult(result);
        onVoiceCommandExecuted?.call(command, intent, result);
        return;
      }

      // ── 3) الدماغ المحلي: معرفة الجهاز + الحوار العام ──
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

      // ── 4) الموصل فشل أو غائب: رد محلي مفيد بدل الطريق المسدود ──
      if (cloud != null) {
        final recovered = await OfflineAssistant.recoverFromConnectorFailure(
          command,
          cloud.error,
          statusCode: cloud.statusCode,
        );
        final spoken = recovered.match != OfflineMatch.none
            ? recovered.reply
            : '${OfflineAssistant.classifyError(cloud.error, statusCode: cloud.statusCode).arabic}. '
                'الأوامر التنفيذية تعمل دون إنترنت.';
        await speak(spoken);
        onAssistantReply?.call(recovered.displayText);
        for (final a in recovered.actions) {
          final r = await AgentDispatcher.execute(a);
          onVoiceCommandExecuted?.call(command, a, r);
        }
        return;
      }
      final message = 'لم أفهم هذا الأمر. اسألني «ماذا تستطيع؟» لأشرح لك.';
      await speak(message);
      onAssistantReply?.call(message);
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
