import 'dart:math' as math;

import '../models/agent_action_intent.dart';
import 'device_knowledge_service.dart';
import 'gemini_service.dart';
import 'intent_parser_service.dart';

/// درجة فهم الدماغ المحلي لرسالة ما.
enum OfflineMatch { none, smalltalk, deviceKnowledge, command }

/// رد الدماغ المحلي: نص منطوق + أوامر تنفيذية مستخرجة.
class OfflineReply {
  const OfflineReply({
    required this.reply,
    this.actions = const <AgentActionIntent>[],
    this.match = OfflineMatch.none,
    this.hint,
  });

  /// النص الذي سيُنطق ويُعرض.
  final String reply;

  /// أوامر تنفيذية استُخرجت محلياً (قد تكون فارغة في الحوار العام).
  final List<AgentActionIntent> actions;

  /// درجة الفهم — تستخدمها الواجهة لتقرر هل تحاول السحابة.
  final OfflineMatch match;

  /// إرشاد اختياري يُضاف للرد (مثل «فعّل Shizuku لتنفيذ هذا»).
  final String? hint;

  bool get isEmpty => reply.trim().isEmpty && actions.isEmpty;
  bool get isCommand => match == OfflineMatch.command;

  OfflineReply withHint(String? h) => h == null || h.isEmpty
      ? this
      : OfflineReply(
          reply: reply,
          actions: actions,
          match: match,
          hint: hint == null ? h : '$hint\n$h',
        );

  /// النص النهائي المعروض (الرد + الإرشاد).
  String get displayText =>
      hint == null || hint!.isEmpty ? reply : '$reply\n\n💡 $hint';
}

/// تصنيف خطأ الموصل — يتيح رداً مناسباً بدل «خطأ غير معروف».
enum ConnectorFailure {
  notConfigured,
  auth,
  rateLimit,
  network,
  timeout,
  model,
  server,
  badResponse,
  unknown,
}

extension ConnectorFailureX on ConnectorFailure {
  String get arabic => switch (this) {
        ConnectorFailure.notConfigured => 'لم يُضبط مزود الذكاء الاصطناعي بعد',
        ConnectorFailure.auth => 'المفتاح مرفوض من المزود (خطأ مصادقة)',
        ConnectorFailure.rateLimit => 'تجاوزت الحد المسموح من الطلبات',
        ConnectorFailure.network => 'لا يوجد اتصال بالإنترنت',
        ConnectorFailure.timeout => 'انتهت مهلة الاتصال بالمزود',
        ConnectorFailure.model => 'الموديل المطلوب غير متاح لدى المزود',
        ConnectorFailure.server => 'خطأ في خادم المزود',
        ConnectorFailure.badResponse => 'رد المزود لم يكن بالصيغة المتوقعة',
        ConnectorFailure.unknown => 'تعذّر الاتصال بالمحرك السحابي',
      };
}

/// الدماغ المحلي للوكيل — **يعمل بالكامل دون إنترنت ودون أي مفتاح**.
///
/// وُجد لسببين:
///  1. أن يرد التطبيق بشكل طبيعي ومفيد عندما يكون الموصل غائباً أو
///     معطلاً أو بلا رصيد، بدل أن يقول «اضبط المفتاح» ويقف.
///  2. أن يجيب فوراً عن كل ما يعرفه عن الجهاز نفسه (التطبيقات المثبتة،
///     البطارية، التخزين، حالة الصلاحيات) — وهذه معرفة محلية أصلاً
///     ولا مبرر لدفع ثمن استدعاء سحابي مقابلها.
///
/// يُستدعى في ثلاثة مواضع:
///  - **قبل** السحابة: إن فهم الأمر محلياً نفّذه فوراً (أسرع + مجاني).
///  - **عند غياب** السحابة: يكون هو الرد النهائي.
///  - **بعد فشل** السحابة: يحوّل الخطأ إلى رد مفيد + إرشاد قابل للتنفيذ.
class OfflineAssistant {
  OfflineAssistant._();

  static final math.Random _rng = math.Random();

  // ═══════════════════════════════════════════
  //  نقطة الدخول الرئيسية
  // ═══════════════════════════════════════════

  /// معالجة رسالة معالجةً محلية كاملة.
  ///
  /// الترتيب: أوامر تنفيذية → معرفة الجهاز → حوار عام → اعتراف بالعجز
  /// (مع اقتراح صياغات تعمل محلياً بدل الرد الفارغ).
  static Future<OfflineReply> respond(String rawText) async {
    final text = rawText.trim();
    if (text.isEmpty) {
      return const OfflineReply(reply: '', match: OfflineMatch.none);
    }

    final n = DeviceKnowledgeService.normalizeArabic(text);

    // 1) أوامر تنفيذية يفهمها المحلل المحلي
    final intent = IntentParserService.parseLocal(text);
    if (intent != null) {
      final reply = _describeIntent(intent);
      return OfflineReply(
        reply: reply,
        actions: <AgentActionIntent>[intent],
        match: OfflineMatch.command,
      );
    }

    // 2) معرفة الجهاز: «ما هي التطبيقات المثبتة؟» «كم البطارية؟»
    final knowledge = await _answerDeviceKnowledge(n, text);
    if (knowledge != null) return knowledge;

    // 3) حوار عام: تحية/شكر/وداع/سؤال عن الهوية/حساب/وقت
    final talk = _answerSmalltalk(n);
    if (talk != null) return talk;

    // 4) لم نفهم — اعتراف صريح + اقتراحات تعمل دون إنترنت
    return OfflineReply(
      reply: _fallbackReply(n),
      match: OfflineMatch.none,
      hint: GeminiService.isConfigured
          ? null
          : 'أعمل دون إنترنت لهذه الأوامر: فتح تطبيق، واي فاي، بيانات، '
              'بلوتوث، سطوع، صوت، اتصال برقم، ما هي التطبيقات المثبتة، '
              'كم البطارية، حالة الشيزوكو. للحوار الحر اضبط مفتاح المزود من ⚙️.',
    );
  }

  // ═══════════════════════════════════════════
  //  1) وصف الأمر المنوي تنفيذه
  // ═══════════════════════════════════════════

  /// صياغة عربية قصيرة تؤكّد ما فهمه الوكيل — تُنطق قبل التنفيذ.
  static String _describeIntent(AgentActionIntent i) {
    final when = i.isScheduled ? _whenPhrase(i.scheduledTime!) : '';
    final p = i.parameters;

    switch (i.actionType) {
      case AgentActionTypes.toggleWifi:
        return '$when${p['enable'] == true ? 'سأشغّل' : 'سأطفئ'} الواي فاي.';
      case AgentActionTypes.toggleMobileData:
        return '$when${p['enable'] == true ? 'سأشغّل' : 'سأطفئ'} بيانات الجوال.';
      case AgentActionTypes.toggleBluetooth:
        return '$when${p['enable'] == true ? 'سأشغّل' : 'سأطفئ'} البلوتوث.';
      case AgentActionTypes.toggleAirplane:
        return '$when${p['enable'] == true ? 'سأفعّل' : 'سألغي'} وضع الطيران.';
      case AgentActionTypes.toggleFlashlight:
        return '$when${p['enable'] == true ? 'سأشعل' : 'سأطفئ'} الكشاف.';
      case AgentActionTypes.openApp:
        return '$whenسأفتح ${i.targetApp ?? 'التطبيق'}.';
      case AgentActionTypes.uninstallApp:
        return 'سأطلب إلغاء تثبيت ${i.targetApp ?? 'التطبيق'}.';
      case AgentActionTypes.forceStopApp:
        return 'سأوقف ${i.targetApp ?? 'التطبيق'} إجبارياً.';
      case AgentActionTypes.clearAppCache:
        return 'سأمسح ذاكرة ${i.targetApp ?? 'التطبيق'} المؤقتة.';
      case AgentActionTypes.appInfo:
        return 'سأعرض تفاصيل ${i.targetApp ?? 'التطبيق'}.';
      case AgentActionTypes.appFiles:
        return 'سأعرض ملفات ${i.targetApp ?? 'التطبيق'}.';
      case AgentActionTypes.call:
        final slot = (p['slotIndex'] as num?)?.toInt() ?? 0;
        return '$whenسأتصل بـ ${p['phoneNumber']} من الشريحة ${slot + 1}.';
      case AgentActionTypes.payment:
        final amount = p['amount'];
        return 'هذه عملية مالية'
            '${amount != null ? ' بمبلغ $amount' : ''}'
            ' — سأعرضها للتأكيد قبل التنفيذ.';
      case AgentActionTypes.setBrightness:
        return 'سأضبط السطوع على ${p['percent']}%.';
      case AgentActionTypes.setVolume:
        return 'سأضبط الصوت على ${p['percent']}%.';
      case AgentActionTypes.setDnd:
        return p['enable'] == true
            ? 'سأفعّل وضع عدم الإزعاج.'
            : 'سألغي وضع عدم الإزعاج.';
      case AgentActionTypes.rebootDevice:
        return 'سأعيد تشغيل الجهاز — هذه خطوة تحتاج صلاحية نظام.';
      case AgentActionTypes.lockScreen:
        return 'سأقفل الشاشة.';
      case AgentActionTypes.screenshot:
        return 'سألتقط صورة للشاشة.';
      case AgentActionTypes.navigateUi:
        final where = switch (p['target']) {
          'back' => 'للخلف',
          'home' => 'للشاشة الرئيسية',
          'recents' => 'لقائمة التطبيقات الأخيرة',
          _ => 'للخلف',
        };
        return 'سأعود $where.';
      case AgentActionTypes.mediaControl:
        final op = switch (p['op']) {
          'pause' => 'سأوقف الوسائط مؤقتاً',
          'next' => 'سأنتقل للمقطع التالي',
          'prev' => 'سأعود للمقطع السابق',
          _ => 'سأشغّل الوسائط',
        };
        return '$op.';
      case AgentActionTypes.openUrl:
        return 'سأفتح الرابط.';
      case AgentActionTypes.searchWeb:
        return 'سأبحث عن «${p['query'] ?? ''}» في المتصفح.';
      case AgentActionTypes.sendMessage:
        return 'سأفتح محادثة إلى ${p['phoneNumber'] ?? p['target'] ?? ''}.';
      case AgentActionTypes.shellCommand:
        return 'سأنفّذ أمر النظام المطلوب.';
      case AgentActionTypes.deviceInfo:
      case AgentActionTypes.batteryInfo:
      case AgentActionTypes.storageInfo:
      case AgentActionTypes.listApps:
      case AgentActionTypes.listFiles:
      case AgentActionTypes.findFile:
        return ''; // تُنتج هذه معلومات لا تنفيذاً — الرد يأتي من المعرفة
      default:
        return '';
    }
  }

  static String _whenPhrase(DateTime t) {
    final diff = t.difference(DateTime.now());
    if (diff.inMinutes < 1) return 'فوراً ';
    if (diff.inMinutes < 60) return 'بعد ${diff.inMinutes} دقيقة ';
    if (diff.inHours < 24) return 'بعد ${diff.inHours} ساعة ';
    return 'في ${t.day}/${t.month} ';
  }

  // ═══════════════════════════════════════════
  //  2) معرفة الجهاز
  // ═══════════════════════════════════════════

  /// هل السؤال عن الجهاز نفسه؟ ثم الإجابة من البيانات المحلية الحقيقية.
  static Future<OfflineReply?> _answerDeviceKnowledge(
    String n,
    String original,
  ) async {
    final isQuestion = RegExp(
      r'(ما هي|ماهو|ما هو|ما |كم|كيف حال|اعرض|اظهر|ارني|أرني| list|what|how many|show)',
      caseSensitive: false,
    ).hasMatch(n);

    // (أ) التطبيقات المثبتة — جرد حقيقي من PackageManager
    final asksApps = RegExp(
      r'(التطبيقات|تطبيقات|البرامج|برامج|المثبته|المثبتة|apps?|applications)',
      caseSensitive: false,
    ).hasMatch(n);
    if (asksApps &&
        (isQuestion || RegExp(r'(اعرض|اظهر|ارني|أرني|قائمه|قائمة|جرد)').hasMatch(n))) {
      final apps = await DeviceKnowledgeService.listApps(includeSystem: false);
      if (apps.isEmpty) {
        return const OfflineReply(
          reply: 'تعذّر قراءة قائمة التطبيقات من النظام.',
          match: OfflineMatch.deviceKnowledge,
        );
      }
      final launchable = apps.where((a) => a.hasLauncher).toList();
      final list = launchable.isEmpty ? apps : launchable;
      final shown = list.take(30).map((a) => '• ${a.appName}').join('\n');
      final more = list.length - 30;
      return OfflineReply(
        reply: 'لديك ${apps.length} تطبيقاً مثبتاً'
            '${list.length != apps.length ? '، منها ${list.length} يمكن فتحه' : ''}.'
            '\n\n$shown'
            '${more > 0 ? '\n\n… و$more أخرى' : ''}',
        match: OfflineMatch.deviceKnowledge,
      );
    }

    // (ب) البطارية
    if (RegExp(r'(البطاريه|البطارية|الشحن|battery)').hasMatch(n)) {
      final s = await DeviceKnowledgeService.deviceSnapshot(force: true);
      if (s.batteryPercent < 0) {
        return const OfflineReply(
          reply: 'تعذّرت قراءة مستوى البطارية.',
          match: OfflineMatch.deviceKnowledge,
        );
      }
      return OfflineReply(
        reply: 'البطارية عند ${s.batteryPercent}% '
            '${s.isCharging ? 'وهي تشحن الآن' : 'وليست على الشاحن'}.\n'
            'حالتها: ${s.batteryHealth}.',
        match: OfflineMatch.deviceKnowledge,
      );
    }

    // (ج) التخزين / المساحة
    if (RegExp(r'(التخزين|المساحه|المساحة|الذاكره|الذاكرة|storage|memory)').hasMatch(n)) {
      final s = await DeviceKnowledgeService.deviceSnapshot(force: true);
      if (s.storageTotalBytes <= 0) {
        return const OfflineReply(
          reply: 'تعذّرت قراءة معلومات التخزين.',
          match: OfflineMatch.deviceKnowledge,
        );
      }
      return OfflineReply(
        reply: 'المساحة المتبقية '
            '${DeviceKnowledgeService.humanSize(s.storageFreeBytes)} '
            'من ${DeviceKnowledgeService.humanSize(s.storageTotalBytes)}.\n'
            'المستخدم ${s.storageUsedPercent}%.',
        match: OfflineMatch.deviceKnowledge,
      );
    }

    // (د) حالة الجهاز/الصلاحيات — «ما حالة الوكيل؟» «هل الشيزوكو شغال؟»
    if (RegExp(
      r'(حاله|حالة|الحاله|الحالة|shizuku|شيزوكو|امكانيه الوصول|إمكانية الوصول|الصلاحيات|الوضع)',
    ).hasMatch(n)) {
      final s = await DeviceKnowledgeService.deviceSnapshot(force: true);
      return OfflineReply(
        reply: s.arabicSummary,
        match: OfflineMatch.deviceKnowledge,
      );
    }

    // (هـ) معلومات الجهاز — «ما نوع جهازي؟» «أي أندرويد؟»
    if (RegExp(r'(جهازي|الجهاز|الهاتف|الموبايل|نوع|اصدار|إصدار|اندرويد|أندرويد|android|device|model)')
        .hasMatch(n)) {
      final s = await DeviceKnowledgeService.deviceSnapshot();
      return OfflineReply(
        reply: 'جهازك ${s.model}، يعمل بأندرويد ${s.androidVersion} '
            '(API ${s.sdkInt}).',
        match: OfflineMatch.deviceKnowledge,
      );
    }

    // (و) «هل تطبيق X مثبت؟» / «ما تفاصيل X؟»
    final installedQ = RegExp(
      r'(هل|وش|ايش)\s+(.+?)\s+(مثبت|مثبته|موجود|منزل|نزل)',
    ).firstMatch(n);
    if (installedQ != null) {
      final name = installedQ.group(2)!.trim();
      final hits = await DeviceKnowledgeService.findApp(name);
      if (hits.isEmpty) {
        return OfflineReply(
          reply: 'لا، لم أجد «$name» بين التطبيقات المثبتة.',
          match: OfflineMatch.deviceKnowledge,
        );
      }
      final a = hits.first;
      return OfflineReply(
        reply: 'نعم، ${a.appName} مثبت.\n'
            'المعرّف: ${a.packageName}\n'
            'الإصدار: ${a.versionName}\n'
            '${a.isSystem ? 'تطبيق نظام' : 'تطبيق مستخدم'}'
            '${a.enabled ? '' : ' — معطّل حالياً'}',
        match: OfflineMatch.deviceKnowledge,
      );
    }

    // (ز) الوقت والتاريخ
    if (RegExp(r'(الساعه كم|كم الساعه|الوقت|التاريخ|اليوم كم|what time|date)').hasMatch(n)) {
      final now = DateTime.now();
      final h = now.hour > 12 ? now.hour - 12 : (now.hour == 0 ? 12 : now.hour);
      final period = now.hour < 12 ? 'صباحاً' : now.hour < 17 ? 'عصراً' : 'مساءً';
      return OfflineReply(
        reply: 'الآن $h:${now.minute.toString().padLeft(2, '0')} $period، '
            'وتاريخ اليوم ${now.day}/${now.month}/${now.year}.',
        match: OfflineMatch.deviceKnowledge,
      );
    }

    // (ح) عملية حسابية — «كم 15 × 4؟»
    final calc = _tryCalculate(n);
    if (calc != null) {
      return OfflineReply(reply: calc, match: OfflineMatch.deviceKnowledge);
    }

    return null;
  }

  /// حساب بسيط محلي: جمع/طرح/ضرب/قسمة على رقمين.
  static String? _tryCalculate(String n) {
    final m = RegExp(
      r'(?:كم|احسب|احسبي|calc)?\s*(-?\d+(?:\.\d+)?)\s*(\+|-|\*|x|×|/|÷|plus|minus)\s*(-?\d+(?:\.\d+)?)',
    ).firstMatch(n);
    if (m == null) return null;
    final a = double.tryParse(m.group(1)!);
    final b = double.tryParse(m.group(3)!);
    if (a == null || b == null) return null;
    final op = m.group(2)!;
    final result = switch (op) {
      '+' || 'plus' => a + b,
      '-' || 'minus' => a - b,
      '*' || 'x' || '×' => a * b,
      '/' || '÷' => b == 0 ? double.nan : a / b,
      _ => null,
    };
    if (result == null) return null;
    if (result.isNaN || result.isInfinite) return 'لا يمكن القسمة على صفر.';
    final text = result == result.roundToDouble()
        ? result.toInt().toString()
        : result.toStringAsFixed(2);
    final opArabic = switch (op) {
      '+' || 'plus' => 'زائد',
      '-' || 'minus' => 'ناقص',
      '*' || 'x' || '×' => 'ضرب',
      _ => 'على',
    };
    return '${m.group(1)} $opArabic ${m.group(3)} يساوي $text.';
  }

  // ═══════════════════════════════════════════
  //  3) الحوار العام دون إنترنت
  // ═══════════════════════════════════════════

  static OfflineReply? _answerSmalltalk(String n) {
    String pick(List<String> options) => options[_rng.nextInt(options.length)];

    // تحية
    if (RegExp(r'^(السلام|سلام|اهلا|أهلا|مرحبا|هلا|هاي|صباح الخير|مساء الخير|hello|hi)(?:[\s!,.؟?]|$)')
        .hasMatch(n)) {
      if (RegExp(r'(صباح)').hasMatch(n)) {
        return OfflineReply(
          reply: pick(<String>[
            'صباح النور والبركة، كيف أقدر أخدمك؟',
            'صباح الخير، أنا جاهز لأمرك.',
          ]),
          match: OfflineMatch.smalltalk,
        );
      }
      if (RegExp(r'(مساء)').hasMatch(n)) {
        return OfflineReply(
          reply: pick(<String>['مساء النور، تفضل أمرك.', 'مساء الخير، كيف حالك؟']),
          match: OfflineMatch.smalltalk,
        );
      }
      // السلام يُردّ عليه بالسلام دائماً، وبقية التحايا بردّ عام
      final isSalam = RegExp(r'(سلام)').hasMatch(n);
      return OfflineReply(
        reply: isSalam
            ? pick(<String>[
                'وعليكم السلام ورحمة الله وبركاته، تفضل أمرك.',
                'وعليكم السلام ورحمة الله، كيف أقدر أساعدك؟',
              ])
            : pick(<String>[
                'أهلاً بك، أنا الوكيل — اطلب ما تريد.',
                'هلا والله، تفضل أمرك.',
              ]),
        match: OfflineMatch.smalltalk,
      );
    }

    // السؤال عن الحال
    if (RegExp(r'(كيف حالك|كيفك|وش اخبارك|شخبارك|كيف الامور|احوالك|أحوالك)').hasMatch(n)) {
      return OfflineReply(
        reply: pick(<String>[
          'بخير والحمد لله، جاهز للعمل. وأنت كيف حالك؟',
          'تمام، وكلّي استعداد لخدمتك.',
        ]),
        match: OfflineMatch.smalltalk,
      );
    }

    // الشكر
    if (RegExp(r'(شكرا|شكراً|مشكور|يعطيك العافيه|تسلم|thank)').hasMatch(n)) {
      return OfflineReply(
        reply: pick(<String>['العفو، تحت أمرك في أي وقت.', 'لا شكر على واجب.', 'حاضر، أنا هنا.']),
        match: OfflineMatch.smalltalk,
      );
    }

    // الهوية: «من أنت؟» «ما اسمك؟»
    if (RegExp(r'(من انت|من أنت|ما اسمك|وش اسمك|عرفني عليك|انت مين|who are you)').hasMatch(n)) {
      return OfflineReply(
        reply: 'أنا «وكيل الأتمتة» — مساعد عربي يتحكم بجهازك صوتاً ونصاً.\n'
            'أفتح التطبيقات، وأدير الشبكة والاتصالات والجدولة، '
            'وأتحكم بواجهات التطبيقات عبر خدمة إمكانية الوصول، '
            'وأنفّذ أوامر النظام العميقة عبر Shizuku.\n'
            'وأعمل في جزء كبير من هذا دون إنترنت.',
        match: OfflineMatch.smalltalk,
      );
    }

    // ما الذي تستطيعه
    if (RegExp(r'(ماذا تستطيع|ماذا تفعل|وش تقدر|ايش تقدر|ما قدراتك|ساعدني|help|ماذا تفعل)')
        .hasMatch(n)) {
      return OfflineReply(
        reply: 'أستطيع — دون إنترنت:\n'
            '• فتح أي تطبيق مثبت بالاسم، ومعرفة ما هو مثبت على جهازك\n'
            '• تشغيل/إطفاء الواي فاي والبيانات والبلوتوث ووضع الطيران والكشاف\n'
            '• ضبط السطوع والصوت ووضع عدم الإزعاج\n'
            '• الاتصال برقم مع تحديد الشريحة، وجدولة الأوامر بوقت مستقبلي\n'
            '• إدارة التطبيقات: تفاصيل، إيقاف إجباري، مسح الكاش، إلغاء تثبيت\n'
            '• قراءة ملفات التطبيقات ومساراتها\n'
            '• الإجابة عن البطارية والتخزين ومعلومات الجهاز والوقت والحساب\n'
            '• التحكم بواجهة أي تطبيق مفتوح: نقر على نص أو معرّف، وكتابة في الحقول\n\n'
            'وبمفتاح ذكاء اصطناعي أضيف: الحوار الحر، وفهم الأوامر المركبة والغامضة.',
        match: OfflineMatch.smalltalk,
      );
    }

    // وداع
    if (RegExp(r'(مع السلامه|مع السلامة|باي|وداعا|إلى اللقاء|الى اللقاء|bye)').hasMatch(n)) {
      return OfflineReply(
        reply: pick(<String>['في أمان الله، نادني متى احتجت.', 'مع السلامة، أنا هنا متى رجعت.']),
        match: OfflineMatch.smalltalk,
      );
    }

    // تأكيد / نفي
    if (RegExp(r'^(نعم|اي|أي|ايوه|أيوه|اكيد|أكيد|موافق|yes|ok|y)$').hasMatch(n)) {
      return OfflineReply(
        reply: 'حاضر. حدّد لي المطلوب وسأنفّذه.',
        match: OfflineMatch.smalltalk,
      );
    }
    if (RegExp(r'^(لا|كلا|الغ|إلغاء|الغاء|cancel|no)$').hasMatch(n)) {
      return OfflineReply(
        reply: 'تمام، ألغيت. أخبرني إن احتجت شيئاً آخر.',
        match: OfflineMatch.smalltalk,
      );
    }

    return null;
  }

  // ═══════════════════════════════════════════
  //  4) الاعتراف بالعجز بطريقة مفيدة
  // ═══════════════════════════════════════════

  /// بدل «لم أفهم»، نسمّي ما بدا أنه مقصود ونقترح الصياغة التي تعمل.
  static String _fallbackReply(String n) {
    // بدا أنه أمر تنفيذي لكن نقصته معلومة
    if (RegExp(r'(اتصل|كلم)').hasMatch(n) && !RegExp(r'\d{6,}').hasMatch(n)) {
      return 'أستطيع الاتصال مباشرة إن أعطيتني الرقم — مثل «اتصل بـ 712345678».\n'
          'الاتصال باسم شخص يحتاج الوصول لجهات الاتصال، وهذا غير مفعّل حالياً.';
    }
    if (RegExp(r'(افتح|شغل)').hasMatch(n)) {
      return 'لم أتعرف على التطبيق المقصود. جرّب «ما هي التطبيقات المثبتة؟» '
          'لترى الأسماء الدقيقة كما يقرأها النظام، ثم اطلبه باسمه.';
    }
    if (RegExp(r'(ارسل|رسالة|رسايل|واتساب|send)').hasMatch(n)) {
      return 'أستطيع فتح واتساب أو تطبيق الرسائل لك، لكن صياغة نص الرسالة '
          'وإرسالها تحتاج محرك الذكاء الاصطناعي أو خدمة إمكانية الوصول.\n'
          'قل «افتح واتساب» وسأنفّذها الآن.';
    }
    if (RegExp(r'(ابحث|بحث|دور|search)').hasMatch(n)) {
      return 'أستطيع فتح المتصفح على نتيجة بحث — قل «ابحث في المتصفح عن كذا».\n'
          'البحث الذكي نفسه يحتاج اتصالاً بالمزود.';
    }
    if (RegExp(r'(ترجم|ترجمه|ترجمة|translate)').hasMatch(n)) {
      return 'الترجمة تحتاج محرك الذكاء الاصطناعي لأنها فهم لغوي لا قاعدة ثابتة.\n'
          'اضبط مفتاح المزود من ⚙️ ثم أعد الطلب.';
    }
    if (RegExp(r'(ذكاء|شاطر|غبي|فاهم|تفهم)').hasMatch(n)) {
      return 'أفهم الأوامر التنفيذية محلياً بقواعد عربية، وأفهم الحوار الحر '
          'عبر مزود ذكاء اصطناعي عند ضبط مفتاحه.\n'
          'اسألني «ماذا تستطيع؟» لترى القائمة الكاملة.';
    }

    return 'لم أفهم هذا الطلب بدقة.\n'
        'أنا أعمل الآن دون اتصال بالمحرك السحابي، فأستطيع تنفيذ أوامر الجهاز '
        'والإجابة عن التطبيقات المثبتة والبطارية والتخزين.\n'
        'جرّب: «افتح واتساب»، «اطفئ البيانات»، «ما هي التطبيقات المثبتة؟»، '
        '«كم البطارية؟»، أو «ماذا تستطيع؟».';
  }

  // ═══════════════════════════════════════════
  //  5) معالجة فشل الموصل
  // ═══════════════════════════════════════════

  /// تصنيف خطأ الموصل من رسالة الخطأ/رمز HTTP.
  static ConnectorFailure classifyError(String? error, {int? statusCode}) {
    final e = (error ?? '').toLowerCase();
    if (statusCode != null) {
      if (statusCode == 401 || statusCode == 403) return ConnectorFailure.auth;
      if (statusCode == 429) return ConnectorFailure.rateLimit;
      if (statusCode == 404) return ConnectorFailure.model;
      if (statusCode >= 500) return ConnectorFailure.server;
    }
    if (e.contains('لا اتصال') ||
        e.contains('socketexception') ||
        e.contains('failed host lookup') ||
        e.contains('network is unreachable')) {
      return ConnectorFailure.network;
    }
    if (e.contains('timeout') || e.contains('مهلة')) return ConnectorFailure.timeout;
    if (e.contains('401') ||
        e.contains('403') ||
        e.contains('invalid api key') ||
        e.contains('authentication') ||
        e.contains('مفتاح')) {
      return ConnectorFailure.auth;
    }
    if (e.contains('429') || e.contains('rate limit') || e.contains('quota')) {
      return ConnectorFailure.rateLimit;
    }
    if (e.contains('404') || e.contains('model_not_found') || e.contains('does not exist')) {
      return ConnectorFailure.model;
    }
    if (e.contains('500') || e.contains('502') || e.contains('503') || e.contains('server')) {
      return ConnectorFailure.server;
    }
    if (e.contains('لم يرجع') || e.contains('json')) return ConnectorFailure.badResponse;
    if (e.contains('غير مضبوط')) return ConnectorFailure.notConfigured;
    return ConnectorFailure.unknown;
  }

  /// إرشاد قابل للتنفيذ حسب نوع الفشل.
  static String adviceFor(ConnectorFailure f) => switch (f) {
        ConnectorFailure.notConfigured =>
          'افتح ⚙️ واختر المزود (Groq هو الأسهل والأكثر سخاءً في الحد المجاني) '
              'ثم ألصق المفتاح.',
        ConnectorFailure.auth =>
          'تحقق من أن المفتاح صحيح ومنتهٍ ومن أنه يخص المزود المختار '
              '(${GeminiService.providerLabel}) — مفاتيح Groq تبدأ بـ gsk_ '
              'ومفاتيح OpenAI بـ sk-.',
        ConnectorFailure.rateLimit =>
          'انتظر دقيقة وأعد المحاولة، أو بدّل الموديل من ⚙️ إلى موديل أرخص/مجاني.',
        ConnectorFailure.network =>
          'تحقق من اتصال الإنترنت. الأوامر التنفيذية المحلية تعمل دون إنترنت.',
        ConnectorFailure.timeout =>
          'الاستجابة بطيئة — جرّب موديلاً أصغر من ⚙️ أو تحقق من سرعة الاتصال.',
        ConnectorFailure.model =>
          'اسم الموديل غير صحيح لدى ${GeminiService.providerLabel}. '
              'صحّحه من ⚙️ (الافتراضي المقترح: ${GeminiService.model}).',
        ConnectorFailure.server =>
          'العطل من خادم المزود نفسه — أعد المحاولة بعد قليل أو بدّل المزود من ⚙️.',
        ConnectorFailure.badResponse =>
          'رد المزود لم يكن JSON صالحاً. أعد الصياغة أو بدّل الموديل.',
        ConnectorFailure.unknown => 'أعد المحاولة، وتحقق من المفتاح والاتصال.',
      };

  /// عند فشل السحابة: نحوّل الخطأ إلى رد مفيد + نجيب محلياً إن أمكن.
  ///
  /// هذا ما يجعل التطبيق «يتفاعل ويرد بشكل طبيعي حتى مع غياب الموصل»:
  /// المستخدم لا يرى كومة أخطاء، بل يرى جواباً محلياً إن وُجد + تشخيصاً دقيقاً.
  static Future<OfflineReply> recoverFromConnectorFailure(
    String userText,
    String? error, {
    int? statusCode,
  }) async {
    final failure = classifyError(error, statusCode: statusCode);
    final local = await respond(userText);

    final diagnosis = '⚠️ ${failure.arabic}.\n${adviceFor(failure)}';

    if (!local.isEmpty && local.match != OfflineMatch.none) {
      // وجدنا جواباً محلياً — نقدّمه ونذكر العطل باختصار
      return OfflineReply(
        reply: '${local.reply}\n\n$diagnosis',
        actions: local.actions,
        match: local.match,
      );
    }

    return OfflineReply(
      reply: '$diagnosis\n\n${local.reply}',
      actions: const <AgentActionIntent>[],
      match: OfflineMatch.none,
      hint: 'كل الأوامر التنفيذية (شبكة/تطبيقات/اتصال/جدولة) تعمل دون إنترنت.',
    );
  }
}
