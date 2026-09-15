import 'dart:convert';
import 'dart:io';

import '../models/agent_action_intent.dart';
import 'device_knowledge_service.dart';
import 'gemini_service.dart';

/// نتيجة استخراج وقت الجدولة من النص.
class _ScheduleExtraction {
  const _ScheduleExtraction(this.time, this.remaining);
  final DateTime? time;
  final String remaining;
}

/// ناتج تحليل فوري قبل تحويله إلى AgentActionIntent.
class _ParsedAction {
  const _ParsedAction({
    required this.actionType,
    required this.category,
    this.targetApp,
    this.parameters = const <String, dynamic>{},
    this.requiresConfirmation = false,
  });

  final String actionType;
  final ActionCategory category;
  final String? targetApp;
  final Map<String, dynamic> parameters;
  final bool requiresConfirmation;
}

/// محرك تحليل الأوامر (المرحلة 4 + المرحلة 6).
///
/// المستويات الثلاثة، بالترتيب:
///  1. **محلل محلي فوري** — قواعد عربية (تطبيع + Regex) تغطي ~35 نوع أمر.
///     يعمل بالكامل دون إنترنت ودون مفتاح.
///  2. **حلّ أسماء التطبيقات من الجهاز** — يعالج المحلل الاسم إلى معرّف حزمة
///     *موجود فعلاً* على جهاز المستخدم عبر PackageManager، بدل الاعتماد
///     على خريطة مكتوبة يدوياً (التي تبقى كاحتياط للأسماء الشائعة).
///  3. **ربط سحابي** للمعقّد والغامض — يُستدعى فقط عند فشل المستويين.
///
/// الواجهة تستدعي [parseLocalAsync] (غير متزامن ظاهرياً لكنه يحلّ الحزم)
/// أو [parseLocal] المتزامن عندما تكون الحزمة غير مهمة.
class IntentParserService {
  IntentParserService._();

  // ═══════════════════════════════════════════
  //  نقاط الدخول
  // ═══════════════════════════════════════════

  /// تحليل متزامن — يعيد null إذا لم يفهم الأمر.
  /// لا يحلّ معرّفات الحزم من الجهاز (المفرّق يفعلها لاحقاً عند الحاجة).
  static AgentActionIntent? parseLocal(String rawText) => parse(rawText);

  /// تحليل متزامن — الاسم المستقر التاريخي.
  static AgentActionIntent? parse(String rawText) {
    final action = _parseAction(rawText);
    if (action == null) return null;
    return _build(rawText, action.action, action.scheduleTime);
  }

  /// **النقطة الأساسية للواجهة**: تحليل محلي + حلّ معرّف الحزمة من الجهاز.
  ///
  /// يعيد null فقط عندما لا يفهم الأمر إطلاقاً — وعندها يجرب المستدعي
  /// المحرك السحابي أو الدماغ المحلي.
  static Future<AgentActionIntent?> parseLocalAsync(String rawText) async {
    final parsed = _parseAction(rawText);
    if (parsed == null) return null;

    var action = parsed.action;

    // حلّ معرّف الحزمة من الجهاز إن كان الأمر يستهدف تطبيقاً ولم تُعرف الحزمة
    if (_needsPackage(action) &&
        (action.parameters['packageName'] as String? ?? '').isEmpty) {
      final name = action.targetApp ??
          (action.parameters['appName'] as String?) ??
          (action.parameters['walletName'] as String?);
      if (name != null && name.isNotEmpty) {
        final resolved = await DeviceKnowledgeService.resolvePackage(name);
        if (resolved != null) {
          action = _ParsedAction(
            actionType: action.actionType,
            category: action.category,
            // نستخدم الاسم الحقيقي من النظام — أدق مما قاله المستخدم
            targetApp: resolved.appName,
            parameters: <String, dynamic>{
              ...action.parameters,
              'packageName': resolved.packageName,
              'appName': resolved.appName,
              'resolvedFromDevice': true,
            },
            requiresConfirmation: action.requiresConfirmation,
          );
        } else {
          // الاسم غير موجود على الجهاز — نحاول الخريطة المكتوبة احتياطاً
          final fallback = _resolvePackage(name);
          if (fallback != null) {
            action = _ParsedAction(
              actionType: action.actionType,
              category: action.category,
              targetApp: action.targetApp,
              parameters: <String, dynamic>{
                ...action.parameters,
                'packageName': fallback,
              },
              requiresConfirmation: action.requiresConfirmation,
            );
          } else {
            // نعلّم النيّة بأن التطبيق غير معروف حتى يسأل المفرّق المستخدم
            action = _ParsedAction(
              actionType: action.actionType,
              category: action.category,
              targetApp: action.targetApp,
              parameters: <String, dynamic>{
                ...action.parameters,
                'appNotFound': true,
              },
              requiresConfirmation: action.requiresConfirmation,
            );
          }
        }
      }
    }

    return _build(rawText, action, parsed.scheduleTime);
  }

  /// هل هذا النوع من الأوامر يحتاج معرّف حزمة ليعمل؟
  static bool _needsPackage(_ParsedAction a) {
    const needs = <String>{
      AgentActionTypes.openApp,
      AgentActionTypes.appInfo,
      AgentActionTypes.uninstallApp,
      AgentActionTypes.forceStopApp,
      AgentActionTypes.clearAppCache,
      AgentActionTypes.appFiles,
      AgentActionTypes.payment,
      AgentActionTypes.sendMessage,
    };
    return needs.contains(a.actionType);
  }

  /// المحلل الهجين: محلي أولاً (مع حلّ الحزم)، ثم السحابة للمعقّد.
  static Future<AgentActionIntent?> parseSmart(
    String rawText, {
    String? geminiApiKey,
  }) async {
    final local = await parseLocalAsync(rawText);
    if (local != null) return local;

    final key = (geminiApiKey != null && geminiApiKey.trim().isNotEmpty)
        ? geminiApiKey.trim()
        : GeminiService.apiKey;
    if (key.isEmpty) return null;

    return parseWithGemini(rawText, apiKey: key);
  }

  // ═══════════════════════════════════════════
  //  نواة المحلل المحلي
  // ═══════════════════════════════════════════

  /// نتيجة التحليل المحلي: الأمر + وقت الجدولة المستخرج.
  ///
  /// داخلي — نقاط الدخول العامة هي [parse] (متزامن) و[parseLocalAsync]
  /// (يحلّ معرّفات الحزم من الجهاز). إبقاؤه خاصاً يمنع تسريب نوع داخلي
  /// إلى الواجهة العامة للمكتبة.
  static _LocalParseResult? _parseAction(String rawText) {
    if (rawText.trim().isEmpty) return null;

    final text = _normalize(rawText);

    // (أ) الجدولة أولاً — «بعد 5 دقائق»، «الساعة 9 مساءً»
    final schedule = _extractSchedule(text);
    final working = schedule.remaining;
    if (working.trim().isEmpty && schedule.time == null) return null;

    // (ب) أمر Shell صريح: «نفذ: svc data enable»
    final shell = RegExp(
      r'^(?:نفذ|تنفيذ|نفذي|امر|امر النظام|شل|shell|run)\s*[:\-]?\s*(.+)$',
      caseSensitive: false,
    ).firstMatch(working);
    if (shell != null) {
      return _LocalParseResult(
        _ParsedAction(
          actionType: AgentActionTypes.shellCommand,
          category: ActionCategory.system,
          parameters: <String, dynamic>{'command': shell.group(1)!.trim()},
          // أوامر Shell حرّة = خطر → تأكيد صريح
          requiresConfirmation: true,
        ),
        schedule.time,
      );
    }

    // (ج) المطابقات بالترتيب — الأكثر تحديداً أولاً
    for (final matcher in _matchers) {
      final action = matcher(working);
      if (action != null) return _LocalParseResult(action, schedule.time);
    }

    return null;
  }

  /// نتيجة داخلية تربط الأمر بوقت جدولته.
  // ── سلسلة المطابقات ──
  // الترتيب مهم: الأوامر المالية والاتصالات قبل «افتح X» العامة،
  // وأوامر التطبيقات المحددة قبل فتح التطبيق.
  static final List<_ParsedAction? Function(String)> _matchers =
      <_ParsedAction? Function(String)>[
    _matchPayment,
    _matchCall,
    _matchSendMessage,
    _matchSendEmail,
    _matchNetwork,
    _matchBluetooth,
    _matchAirplane,
    _matchFlashlight,
    _matchBrightness,
    _matchVolume,
    _matchRotation,
    _matchDnd,
    _matchMedia,
    _matchNavigation,
    _matchScreenshot,
    _matchLockScreen,
    _matchReboot,
    _matchSettingsPage,
    _matchCamera,
    _matchContacts,
    _matchWebSearch,
    _matchOpenUrl,
    _matchBatteryInfo,
    _matchStorageInfo,
    _matchDeviceInfo,
    _matchListApps,
    _matchAppFiles,
    _matchFindFile,
    _matchListFiles,
    _matchUninstallApp,
    _matchForceStopApp,
    _matchClearCache,
    _matchAppInfo,
    _matchUiClick,
    _matchUiSetText,
    _matchOpenApp, // دائماً أخيراً — الأكثر عمومية
  ];

  // ═══════════════════════════════════════════
  //  الشبكة والاتصال
  // ═══════════════════════════════════════════

  /// الدفع والتحويل: «حول 5000 ريال من محفظة جوادي»، «افتح محفظة كذا».
  static _ParsedAction? _matchPayment(String text) {
    final hasWallet = RegExp(
      r'(محفظه|محفظ|وايت|كاش|موبايل موني|جوايدي|جوادي|كرمي|يمن كاش|ون كاش|بنك|محفظتي)',
    ).hasMatch(text);
    if (!hasWallet) return null;

    final isTransfer =
        RegExp(r'(حول|تحويل|حواله|ادفع|دفع|ارسل|سدد|اشحن)').hasMatch(text);
    final isOpen = RegExp(r'(افتح|شغل|فتح)').hasMatch(text);
    if (!isTransfer && !isOpen) return null;

    var walletName = _knownWallets.firstWhere(
      (w) => text.contains(DeviceKnowledgeService.normalizeArabic(w)),
      orElse: () => '',
    );
    final walletAfterWord =
        RegExp(r'(?:محفظه|محفظ|وايت)\s+(\S+)').firstMatch(text)?.group(1);
    if (walletName.isEmpty && walletAfterWord != null) {
      walletName = walletAfterWord;
    }
    if (walletName.isEmpty) walletName = 'المحفظة';

    final parameters = <String, dynamic>{'walletName': walletName};

    final amount = RegExp(r'(\d+(?:\.\d+)?)').firstMatch(text)?.group(1);
    if (amount != null) parameters['amount'] = num.tryParse(amount);

    final phone = _extractPhoneNumber(text);
    if (phone != null) parameters['phoneNumber'] = phone;

    final package = _resolvePackage(walletName);
    if (package != null) parameters['packageName'] = package;

    if (isTransfer) {
      return _ParsedAction(
        actionType: AgentActionTypes.payment,
        category: ActionCategory.payment,
        targetApp: walletName,
        parameters: parameters,
        requiresConfirmation: true,
      );
    }
    return _ParsedAction(
      actionType: AgentActionTypes.openApp,
      category: ActionCategory.payment,
      targetApp: walletName,
      parameters: parameters,
    );
  }

  /// الاتصال: «اتصل بـ 712345678 من الشريحة 2».
  static _ParsedAction? _matchCall(String text) {
    if (!RegExp(r'(^|\s)(اتصل|اتصال|كلم|مكالمه|يرن|دق|اتصال هاتفي)(\s|$)').hasMatch(text)) {
      return null;
    }

    var slotIndex = 0;
    final slot = RegExp(
      r'(?:الشريحه|شريحه|الخط|سم|سيم|sim)\s*(\d)',
      caseSensitive: false,
    ).firstMatch(text);
    if (slot != null) {
      slotIndex = (int.tryParse(slot.group(1)!) ?? 1) - 1;
      if (slotIndex < 0) slotIndex = 0;
    }

    final phone = _extractPhoneNumber(text);
    // «اتصل بأحمد» بلا رقم لا يُحل محلياً (يحتاج جهات الاتصال)
    if (phone == null) return null;

    return _ParsedAction(
      actionType: AgentActionTypes.call,
      category: ActionCategory.call,
      parameters: <String, dynamic>{'phoneNumber': phone, 'slotIndex': slotIndex},
    );
  }

  /// الشبكة: «شغل الواي فاي»، «اطفئ البيانات».
  static _ParsedAction? _matchNetwork(String text) {
    final dataKeywords = RegExp(
      r'(بيانات|البيانات|انترنت|الانترنت|داتا|شبكه الهاتف|شبكه الجوال|3ج|4ج|5ج|(?:^|\s)(نت|النت)(?:\s|$))',
    );
    final wifiKeywords = RegExp(
      r'(wifi|شبكه(?! الهاتف)(?! الجوال))',
      caseSensitive: false,
    );

    final isData = dataKeywords.hasMatch(text);
    final isWifi = wifiKeywords.hasMatch(text);
    if (!isData && !isWifi) return null;
    // البلوتوث له مطابقة منفصلة — لا نخلطه بالشبكة
    if (RegExp(r'بلوتوث|bluetooth').hasMatch(text)) return null;
    // «افتح إعدادات الواي فاي» صفحة إعدادات لا تبديل مباشر
    if (nr(r'(اعدادات|الإعدادات|ضبط|صفحه|صفحة)').hasMatch(text)) return null;

    final enable = _detectEnable(text);
    if (enable == null) return null;

    final preferData = isData &&
        (!isWifi || RegExp(r'(هاتف|جوال|بيانات|انترنت|نت)').hasMatch(text));

    return _ParsedAction(
      actionType: preferData
          ? AgentActionTypes.toggleMobileData
          : AgentActionTypes.toggleWifi,
      category: ActionCategory.system,
      parameters: <String, dynamic>{'enable': enable},
    );
  }

  /// البلوتوث: «شغل البلوتوث».
  static _ParsedAction? _matchBluetooth(String text) {
    if (!RegExp(r'(بلوتوث|بلوتوت|bluetooth)', caseSensitive: false).hasMatch(text)) {
      return null;
    }
    final enable = _detectEnable(text);
    if (enable == null) return null;
    return _ParsedAction(
      actionType: AgentActionTypes.toggleBluetooth,
      category: ActionCategory.system,
      parameters: <String, dynamic>{'enable': enable},
    );
  }

  /// وضع الطيران: «فعل وضع الطيران».
  static _ParsedAction? _matchAirplane(String text) {
    if (!RegExp(r'(طيران|الطيران|airplane|flight mode|وضع الطائره)').hasMatch(text)) {
      return null;
    }
    final enable = _detectEnable(text);
    if (enable == null) return null;
    return _ParsedAction(
      actionType: AgentActionTypes.toggleAirplane,
      category: ActionCategory.system,
      parameters: <String, dynamic>{'enable': enable},
    );
  }

  // ═══════════════════════════════════════════
  //  إعدادات الجهاز
  // ═══════════════════════════════════════════

  /// الكشاف: «نور الكشاف»، «شغل الفلاش».
  static _ParsedAction? _matchFlashlight(String text) {
    if (!RegExp(r'(كشاف|فلاش|flash|torch|نور الجوال|اللمبه|اللمبة)').hasMatch(text)) {
      return null;
    }
    // «نور» و«ضوي» تعني التشغيل في هذا السياق
    final enable = _detectEnable(text) ??
        (RegExp(r'(نور|نوري|ضوي|اضوي|ولع)').hasMatch(text) ? true : null);
    if (enable == null) return null;
    return _ParsedAction(
      actionType: AgentActionTypes.toggleFlashlight,
      category: ActionCategory.system,
      parameters: <String, dynamic>{'enable': enable},
    );
  }

  /// السطوع: «ارفع السطوع»، «خل السطوع 50»، «خفت الشاشة».
  static _ParsedAction? _matchBrightness(String text) {
    if (!RegExp(r'(سطوع|السطوع|اضائه|إضاءه|اضاءه|brightness|نور الشاشه|نور الشاشة)')
        .hasMatch(text)) {
      return null;
    }

    final percent = _extractPercent(text);
    if (percent != null) {
      return _ParsedAction(
        actionType: AgentActionTypes.setBrightness,
        category: ActionCategory.system,
        parameters: <String, dynamic>{'percent': percent, 'auto': false},
      );
    }

    // توجيه نسبي بلا رقم
    final up = RegExp(r'(ارفع|زود|زيد|علي|طلع|اعلى|أعلى|bright|رفع)').hasMatch(text);
    final down = RegExp(r'(خفت|اخفض|نقص|وطي|قلل|انزل|dim|خفض)').hasMatch(text);
    if (RegExp(r'(تلقائي|اوتوماتيك|auto)').hasMatch(text)) {
      return _ParsedAction(
        actionType: AgentActionTypes.setBrightness,
        category: ActionCategory.system,
        parameters: <String, dynamic>{'auto': true},
      );
    }
    if (up || down) {
      return _ParsedAction(
        actionType: AgentActionTypes.setBrightness,
        category: ActionCategory.system,
        parameters: <String, dynamic>{'relative': up ? 'up' : 'down', 'auto': false},
      );
    }
    return null;
  }

  /// الصوت: «ارفع الصوت»، «صفر الصوت»، «خل الصوت 30».
  static _ParsedAction? _matchVolume(String text) {
    if (!RegExp(r'(صوت|الصوت|مستوي الصوت|volume|جرس|الرنين|الميديا|الوسائط)')
        .hasMatch(text)) {
      return null;
    }
    // «اسكت الصوت» / «صفر» = كتم
    if (RegExp(r'(اسكت|كتم|اصمت|صمت|صفر|اطفي الصوت|mute)').hasMatch(text)) {
      return _ParsedAction(
        actionType: AgentActionTypes.setVolume,
        category: ActionCategory.media,
        parameters: <String, dynamic>{'percent': 0, 'mute': true},
      );
    }

    final percent = _extractPercent(text);
    if (percent != null) {
      return _ParsedAction(
        actionType: AgentActionTypes.setVolume,
        category: ActionCategory.media,
        parameters: <String, dynamic>{'percent': percent},
      );
    }

    final up = RegExp(r'(ارفع|زود|زيد|علي|طلع|اعلى|louder|رفع)').hasMatch(text);
    final down = RegExp(r'(اخفض|نقص|وطي|قلل|انزل|خفت|softer|خفض)').hasMatch(text);
    if (up || down) {
      return _ParsedAction(
        actionType: AgentActionTypes.setVolume,
        category: ActionCategory.media,
        parameters: <String, dynamic>{'relative': up ? 'up' : 'down'},
      );
    }
    return null;
  }

  /// دوران الشاشة: «اقفل الدوران».
  static _ParsedAction? _matchRotation(String text) {
    if (!RegExp(r'(دوران|الدوران|اتجاه الشاشه|rotation|rotate|افقي|عمودي)')
        .hasMatch(text)) {
      return null;
    }
    final enable = _detectEnable(text);
    final landscape = RegExp(r'(افقي|أفقي|landscape|عرض)').hasMatch(text);
    final portrait = RegExp(r'(عمودي|portrait|طول)').hasMatch(text);

    if (landscape) {
      return _ParsedAction(
        actionType: AgentActionTypes.toggleRotation,
        category: ActionCategory.system,
        parameters: <String, dynamic>{'orientation': 'landscape'},
      );
    }
    if (portrait) {
      return _ParsedAction(
        actionType: AgentActionTypes.toggleRotation,
        category: ActionCategory.system,
        parameters: <String, dynamic>{'orientation': 'portrait'},
      );
    }
    if (enable == null) return null;
    return _ParsedAction(
      actionType: AgentActionTypes.toggleRotation,
      category: ActionCategory.system,
      parameters: <String, dynamic>{'auto': enable},
    );
  }

  /// عدم الإزعاج: «فعل وضع عدم الإزعاج».
  static _ParsedAction? _matchDnd(String text) {
    if (!RegExp(r'(عدم الازعاج|ازعاج|الازعاج|dnd|do not disturb|وضع الصمت|التركيز)')
        .hasMatch(text)) {
      return null;
    }
    final enable = _detectEnable(text);
    if (enable == null) return null;
    return _ParsedAction(
      actionType: AgentActionTypes.setDnd,
      category: ActionCategory.system,
      parameters: <String, dynamic>{'enable': enable},
    );
  }

  // ═══════════════════════════════════════════
  //  الوسائط والواجهة
  // ═══════════════════════════════════════════

  /// الوسائط: «شغل الموسيقى»، «وقف الأغنية»، «المقطع التالي».
  ///
  /// تتطلب ذكراً صريحاً لكلمة وسائط — وإلا ابتلعت أوامر أخرى:
  /// «اوقف يوتيوب إجبارياً» إيقاف تطبيق، و«ارجع» تنقل في الواجهة.
  static _ParsedAction? _matchMedia(String text) {
    final hasMedia = nr(r'(موسيقي|موسيقى|اغنيه|اغاني|ميديا|وسائط|video|music|المقطع|الاغنيه|الصوتيات|الراديو|الانشوده|الأنشودة)')
        .hasMatch(text);
    if (!hasMedia) return null;

    final nextWord = nr(r'(التالي|التاليه|اللي بعده|next|قدم)').hasMatch(text);
    final prevWord = nr(r'(السابق|السابقه|اللي قبله|previous)').hasMatch(text);

    String op;
    if (nextWord) {
      op = 'next';
    } else if (prevWord) {
      op = 'prev';
    } else if (RegExp(r'(وقف|اوقف|اسكت|pause)').hasMatch(text)) {
      op = 'pause';
    } else {
      op = 'play';
    }

    return _ParsedAction(
      actionType: AgentActionTypes.mediaControl,
      category: ActionCategory.media,
      parameters: <String, dynamic>{'op': op},
    );
  }

  /// التنقل: «ارجع»، «الشاشة الرئيسية»، «التطبيقات الأخيرة».
  static _ParsedAction? _matchNavigation(String text) {
    if (RegExp(r'(^|\s)(ارجع|ارجع للخلف|رجوع|back|خلف)(\s|$)').hasMatch(text) ||
        text.trim() == 'back') {
      return _ParsedAction(
        actionType: AgentActionTypes.navigateUi,
        category: ActionCategory.automation,
        parameters: <String, dynamic>{'target': 'back'},
      );
    }
    if (nr(r'(الشاشة الرئيسية|القائمة الرئيسية|هوم|home|الرئيسيه)')
        .hasMatch(text)) {
      return _ParsedAction(
        actionType: AgentActionTypes.navigateUi,
        category: ActionCategory.automation,
        parameters: <String, dynamic>{'target': 'home'},
      );
    }
    if (nr(r'(التطبيقات الاخيرة|المهام الاخيرة|recents|recent apps|التطبيقات المفتوحة)')
        .hasMatch(text)) {
      return _ParsedAction(
        actionType: AgentActionTypes.navigateUi,
        category: ActionCategory.automation,
        parameters: <String, dynamic>{'target': 'recents'},
      );
    }
    return null;
  }

  /// لقطة شاشة: «صور الشاشة».
  static _ParsedAction? _matchScreenshot(String text) {
    if (!RegExp(r'(لقطه شاشه|لقطة شاشة|صور الشاشه|سكرين شوت|screenshot|screen shot)')
        .hasMatch(text)) {
      return null;
    }
    return const _ParsedAction(
      actionType: AgentActionTypes.screenshot,
      category: ActionCategory.system,
    );
  }

  /// قفل الشاشة: «اقفل الشاشة».
  static _ParsedAction? _matchLockScreen(String text) {
    if (!RegExp(r'(اقفل الشاشه|اقفل الشاشة|قفل الشاشه|اطفي الشاشه|lock screen)')
        .hasMatch(text)) {
      return null;
    }
    return const _ParsedAction(
      actionType: AgentActionTypes.lockScreen,
      category: ActionCategory.system,
    );
  }

  /// إعادة تشغيل الجهاز: «اعد تشغيل الجوال».
  static _ParsedAction? _matchReboot(String text) {
    if (!RegExp(r'(اعد تشغيل|إعادة تشغيل|ريستارت|restart|reboot|شغل الجوال من جديد)')
        .hasMatch(text)) {
      return null;
    }
    // «اعد تشغيل الواي فاي» ليس إعادة تشغيل للجهاز
    if (RegExp(r'(wifi|الواي فاي|البيانات|البلوتوث|التطبيق)').hasMatch(text)) return null;
    return const _ParsedAction(
      actionType: AgentActionTypes.rebootDevice,
      category: ActionCategory.system,
      requiresConfirmation: true,
    );
  }

  /// صفحة إعدادات محددة: «افتح اعدادات الواي فاي».
  static _ParsedAction? _matchSettingsPage(String text) {
    if (!nr(r'(اعدادات|settings|ضبط النظام)').hasMatch(text)) return null;

    // «افتح تطبيق الإعدادات» يعالجه _matchOpenApp — هنا الصفحات الفرعية فقط
    final page = RegExp(
      r'(wifi|الواي فاي|الشبكه|الشبكات|البيانات|الجوال المحمول|التطبيقات|البطاريه|البطارية|'
      r'التخزين|الصوت|الشاشه|العرض|الامان|الأمان|الحسابات|البلوتوث|الموقع|الاشعارات|'
      r'امكانيه الوصول|إمكانية الوصول|تاريخ|التاريخ|المطور|المطورين)',
    ).firstMatch(text)?.group(1);
    if (page == null) return null;

    final normalized = DeviceKnowledgeService.normalizeArabic(page);
    return _ParsedAction(
      actionType: AgentActionTypes.openSettingsPage,
      category: ActionCategory.system,
      parameters: <String, dynamic>{'page': _settingsPageKey(normalized)},
    );
  }

  /// خريطة اسم الصفحة → مفتاح يفهمه المفرّق.
  static String _settingsPageKey(String n) {
    if (n.contains('wifi') || n.contains('واي') || n.contains('شبك')) return 'wifi';
    if (n.contains('بيانات') || n.contains('جوال')) return 'data';
    if (n.contains('بلوتوث')) return 'bluetooth';
    if (n.contains('تطبيقات')) return 'apps';
    if (n.contains('بطاري')) return 'battery';
    if (n.contains('تخزين')) return 'storage';
    if (n.contains('صوت')) return 'sound';
    if (n.contains('شاشه') || n.contains('عرض')) return 'display';
    if (n.contains('امان') || n.contains('أمان')) return 'security';
    if (n.contains('حسابات')) return 'accounts';
    if (n.contains('موقع')) return 'location';
    if (n.contains('اشعارات')) return 'notifications';
    if (n.contains('امكانيه') || n.contains('إمكانية')) return 'accessibility';
    if (n.contains('تاريخ')) return 'date';
    if (n.contains('مطور')) return 'developer';
    return 'main';
  }

  /// الكاميرا: «افتح الكاميرا».
  static _ParsedAction? _matchCamera(String text) {
    if (!RegExp(r'(كاميرا|كاميره|camera|صورني|التقاط صوره)').hasMatch(text)) return null;
    if (!RegExp(r'(افتح|شغل|فتح|open)').hasMatch(text)) return null;
    return const _ParsedAction(
      actionType: AgentActionTypes.openCamera,
      category: ActionCategory.system,
    );
  }

  /// جهات الاتصال: «افتح جهات الاتصال».
  static _ParsedAction? _matchContacts(String text) {
    if (!RegExp(r'(جهات الاتصال|الاسماء|الأسماء|اسماء|contacts|دليل الهاتف)')
        .hasMatch(text)) {
      return null;
    }
    return const _ParsedAction(
      actionType: AgentActionTypes.openContacts,
      category: ActionCategory.call,
    );
  }

  /// البحث في الويب: «ابحث في المتصفح عن كذا».
  static _ParsedAction? _matchWebSearch(String text) {
    final m = RegExp(
      r'(ابحث|بحث|دور|فتش|search)\s+(?:في\s+)?(?:المتصفح|جوجل|قوقل|google|الانترنت|النت)?\s*(?:عن|علي|على)?\s+(.+)$',
      caseSensitive: false,
    ).firstMatch(text);
    if (m == null) return null;
    final query = m.group(2)?.trim() ?? '';
    if (query.isEmpty) return null;
    // «ابحث عن ملف X» هو بحث ملفات لا ويب
    if (RegExp(r'(ملف|ملفات|مجلد|صوره|في الجوال|في الجهاز)').hasMatch(query)) {
      return null;
    }
    return _ParsedAction(
      actionType: AgentActionTypes.searchWeb,
      category: ActionCategory.info,
      parameters: <String, dynamic>{'query': query},
    );
  }

  /// فتح رابط: «افتح الرابط https://...».
  static _ParsedAction? _matchOpenUrl(String text) {
    final m = RegExp(r'(https?://[^\s]+)').firstMatch(text);
    if (m == null) return null;
    return _ParsedAction(
      actionType: AgentActionTypes.openUrl,
      category: ActionCategory.info,
      parameters: <String, dynamic>{'url': m.group(1)!},
    );
  }

  /// إرسال رسالة: «ارسل رسالة إلى 712345678».
  static _ParsedAction? _matchSendMessage(String text) {
    if (!RegExp(r'(ارسل|ارسال|ابعث|رساله|رسالة|sms|واتساب|واتس اب|message)')
        .hasMatch(text)) {
      return null;
    }
    final phone = _extractPhoneNumber(text);
    if (phone == null) return null;

    // النص بعد «النص» أو «يقول» أو بين علامتي اقتباس
    final body = RegExp(r'(?:النص|يقول|محتواها|الرساله|الرسالة)\s*[:\-]?\s*(.+)$')
            .firstMatch(text)
            ?.group(1) ??
        RegExp(r'["«](.+?)["»]').firstMatch(text)?.group(1) ??
        '';

    final viaWhats = RegExp(r'(واتساب|واتس اب|whatsapp)').hasMatch(text);
    return _ParsedAction(
      actionType: AgentActionTypes.sendMessage,
      category: ActionCategory.messaging,
      parameters: <String, dynamic>{
        'phoneNumber': phone,
        'text': body.trim(),
        'viaWhatsapp': viaWhats,
      },
    );
  }

  /// بريد: «ارسل ايميل إلى x@y.com».
  static _ParsedAction? _matchSendEmail(String text) {
    final m = RegExp(r'([A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,})')
        .firstMatch(text);
    if (m == null) return null;
    if (!RegExp(r'(ايميل|إيميل|بريد|mail|email|ارسل)').hasMatch(text)) return null;
    final subject = RegExp(r'(?:الموضوع|عنوان)\s*[:\-]?\s*(.+?)(?:\s+و|\s*$)')
            .firstMatch(text)
            ?.group(1) ??
        '';
    return _ParsedAction(
      actionType: AgentActionTypes.sendEmail,
      category: ActionCategory.messaging,
      parameters: <String, dynamic>{'to': m.group(1)!, 'subject': subject.trim()},
    );
  }

  // ═══════════════════════════════════════════
  //  معلومات الجهاز
  // ═══════════════════════════════════════════

  static _ParsedAction? _matchBatteryInfo(String text) {
    if (!nr(r'(البطارية|الشحن|battery)').hasMatch(text)) return null;
    // «إعدادات البطارية» صفحة إعدادات — تعالجها _matchSettingsPage
    if (nr(r'(اعدادات|settings)').hasMatch(text)) return null;
    return const _ParsedAction(
      actionType: AgentActionTypes.batteryInfo,
      category: ActionCategory.info,
    );
  }

  static _ParsedAction? _matchStorageInfo(String text) {
    if (!nr(r'(التخزين|المساحة|storage|الذاكرة الداخلية)').hasMatch(text)) {
      return null;
    }
    if (nr(r'(اعدادات|settings)').hasMatch(text)) return null;
    return const _ParsedAction(
      actionType: AgentActionTypes.storageInfo,
      category: ActionCategory.info,
    );
  }

  static _ParsedAction? _matchDeviceInfo(String text) {
    if (!RegExp(r'(معلومات الجهاز|جهازي|نوع الجهاز|اصدار الاندرويد|إصدار الأندرويد|device info)')
        .hasMatch(text)) {
      return null;
    }
    return const _ParsedAction(
      actionType: AgentActionTypes.deviceInfo,
      category: ActionCategory.info,
    );
  }

  /// جرد التطبيقات: «ما هي التطبيقات المثبتة؟».
  static _ParsedAction? _matchListApps(String text) {
    if (!RegExp(r'(التطبيقات|تطبيقات|البرامج|برامج)').hasMatch(text)) return null;
    if (!RegExp(r'(المثبته|المثبتة|المنزله|كل|قائمه|قائمة|اعرض|اظهر|ارني|أرني|ما هي|ماهى|وش|ايش)')
        .hasMatch(text)) {
      return null;
    }
    final includeSystem = RegExp(r'(النظام|كل التطبيقات|system)').hasMatch(text);
    return _ParsedAction(
      actionType: AgentActionTypes.listApps,
      category: ActionCategory.apps,
      parameters: <String, dynamic>{'includeSystem': includeSystem},
    );
  }

  // ═══════════════════════════════════════════
  //  إدارة التطبيقات
  // ═══════════════════════════════════════════

  /// إلغاء تثبيت: «احذف تيك توك»، «شيل واتساب».
  static _ParsedAction? _matchUninstallApp(String text) {
    final m = RegExp(
      r'(احذف|حذف|شيل|شيلي|الغ تثبيت|إلغاء تثبيت|ازل|أزل|ازاله|إزاله|uninstall|remove)\s+(?:تطبيق\s+|برنامج\s+)?(.+)$',
    ).firstMatch(text);
    if (m == null) return null;
    final name = _cleanAppName(m.group(2)!);
    if (name.isEmpty || _isNotAnApp(name)) return null;
    return _ParsedAction(
      actionType: AgentActionTypes.uninstallApp,
      category: ActionCategory.apps,
      targetApp: name,
      parameters: <String, dynamic>{'appName': name},
      requiresConfirmation: true, // عملية هدّامة → تأكيد صريح
    );
  }

  /// إيقاف إجباري: «اوقف تيك توك».
  static _ParsedAction? _matchForceStopApp(String text) {
    final m = RegExp(
      r'(اوقف|أوقف|اقفل|غلق|force stop|kill)\s+(?:تطبيق\s+|برنامج\s+)?(.+?)\s*(?:اجباريا|إجبارياً|اجباري|بالقوة)?$',
    ).firstMatch(text);
    if (m == null) return null;
    final name = _cleanAppName(m.group(2)!);
    if (name.isEmpty || _isNotAnApp(name)) return null;
    // «اقفل الشاشة» و«اقفل الواي فاي» ليسا إيقاف تطبيق
    if (RegExp(r'(الشاشه|الشاشة|واي|بيانات|بلوتوث)').hasMatch(name)) return null;
    return _ParsedAction(
      actionType: AgentActionTypes.forceStopApp,
      category: ActionCategory.apps,
      targetApp: name,
      parameters: <String, dynamic>{'appName': name},
    );
  }

  /// مسح الكاش: «امسح كاش تيك توك».
  static _ParsedAction? _matchClearCache(String text) {
    if (!RegExp(r'(كاش|cache|ذاكره مؤقته|ذاكرة مؤقتة|المؤقته|تنظيف)').hasMatch(text)) {
      return null;
    }
    final m = RegExp(
      r'(امسح|مسح|نظف|نظفي|احذف|clear|clean)\s+(?:ال)?(?:كاش|cache|الذاكره المؤقته)\s*(?:تطبيق\s+|برنامج\s+|بتاع\s+|لـ\s+)?(.*)$',
    ).firstMatch(text);
    final name = m == null ? '' : _cleanAppName(m.group(1)!);
    return _ParsedAction(
      actionType: AgentActionTypes.clearAppCache,
      category: ActionCategory.apps,
      targetApp: name.isEmpty ? null : name,
      parameters: <String, dynamic>{
        if (name.isNotEmpty) 'appName': name,
        'allApps': name.isEmpty,
      },
    );
  }

  /// تفاصيل تطبيق: «ما تفاصيل واتساب»، «معلومات عن تيك توك».
  static _ParsedAction? _matchAppInfo(String text) {
    final m = RegExp(
      r'(معلومات عن|تفاصيل|تفاصيل عن|معلومات|info about|details)\s+(?:التطبيق\s+|البرنامج\s+)?(.+)$',
    ).firstMatch(text);
    if (m == null) return null;
    final name = _cleanAppName(m.group(2)!);
    if (name.isEmpty || _isNotAnApp(name)) return null;
    return _ParsedAction(
      actionType: AgentActionTypes.appInfo,
      category: ActionCategory.apps,
      targetApp: name,
      parameters: <String, dynamic>{'appName': name},
    );
  }

  /// ملفات تطبيق: «اعرض ملفات واتساب».
  static _ParsedAction? _matchAppFiles(String text) {
    if (!RegExp(r'(ملفات|ملف|مجلد|بيانات)').hasMatch(text)) return null;
    final m = RegExp(
      r'(اعرض|اظهر|ارني|أرني|افتح|شوف|list|show)\s+(?:لي\s+)?(?:ملفات|مجلدات|بيانات)\s+(?:التطبيق\s+|البرنامج\s+)?(.+)$',
    ).firstMatch(text);
    if (m == null) return null;
    final name = _cleanAppName(m.group(2)!);
    if (name.isEmpty || _isNotAnApp(name)) return null;
    // «ملفات التنزيلات» مسار لا تطبيق — يعالجه _matchListFiles
    if (RegExp(r'(التنزيلات|التحميلات|الصور|المستندات|sdcard)').hasMatch(name)) {
      return null;
    }
    return _ParsedAction(
      actionType: AgentActionTypes.appFiles,
      category: ActionCategory.files,
      targetApp: name,
      parameters: <String, dynamic>{'appName': name},
    );
  }

  // ═══════════════════════════════════════════
  //  الملفات
  // ═══════════════════════════════════════════

  /// البحث عن ملفات: «دور على ملفات pdf».
  static _ParsedAction? _matchFindFile(String text) {
    final m = RegExp(
      r'(ابحث|دور|فتش|قلب|find|search)\s+(?:عن|علي|على)?\s*(?:ملفات|ملف)?\s*(.+?)\s*(?:في\s+(.+))?$',
    ).firstMatch(text);
    if (m == null) return null;
    final query = m.group(2)?.trim() ?? '';
    if (query.isEmpty) return null;
    // نرفض ما ليس بحث ملفات
    if (!RegExp(r'(ملف|ملفات|مجلد|صوره|صور|فيديو|مستند|pdf|apk|mp3|mp4|docx|xlsx|jpg|png)')
        .hasMatch(text)) {
      return null;
    }
    if (RegExp(r'(في المتصفح|جوجل|قوقل|google|الانترنت)').hasMatch(text)) return null;
    return _ParsedAction(
      actionType: AgentActionTypes.findFile,
      category: ActionCategory.files,
      parameters: <String, dynamic>{
        'query': query,
        'path': (m.group(3)?.trim().isNotEmpty ?? false)
            ? (_resolvePath(m.group(3)!.trim()) ?? '/sdcard')
            : '/sdcard',
      },
    );
  }

  /// سرد محتويات مجلد: «اعرض ملفات التنزيلات».
  static _ParsedAction? _matchListFiles(String text) {
    // كلمة «ملفات/محتويات/مجلد» إلزامية — بدونها «افتح واتساب»
    // ستبتلعها هذه المطابقة وتعيدها قائمة ملفات بدل فتح التطبيق.
    final m = RegExp(
      r'(?:(اعرض|اظهر|ارني|أرني|شوف|افتح|list|ls)\s+(?:لي\s+)?)?(ملفات|محتويات|مجلدات|مجلد|محتوى)\s+(.+)$',
    ).firstMatch(text);
    if (m == null) return null;
    final raw = m.group(3)!.trim();
    // مسار صريح مذكور في الجملة يُحترم كما هو
    final explicit = RegExp(r'(/\S+)').firstMatch(raw)?.group(1);
    final path = explicit ?? _resolvePath(raw);
    if (path == null) return null;
    return _ParsedAction(
      actionType: AgentActionTypes.listFiles,
      category: ActionCategory.files,
      parameters: <String, dynamic>{'path': path, 'label': raw},
    );
  }

  /// تحويل اسم مجلد عربي إلى مسار فعلي.
  static String? _resolvePath(String raw) {
    if (raw.startsWith('/')) return raw;
    final n = DeviceKnowledgeService.normalizeArabic(raw).toLowerCase();

    const map = <String, String>{
      'التنزيلات': '/sdcard/Download',
      'التحميلات': '/sdcard/Download',
      'download': '/sdcard/Download',
      'downloads': '/sdcard/Download',
      'الصور': '/sdcard/Pictures',
      'صور': '/sdcard/Pictures',
      'pictures': '/sdcard/Pictures',
      'dcim': '/sdcard/DCIM',
      'الكاميرا': '/sdcard/DCIM/Camera',
      'المستندات': '/sdcard/Documents',
      'مستندات': '/sdcard/Documents',
      'documents': '/sdcard/Documents',
      'الموسيقى': '/sdcard/Music',
      'موسيقي': '/sdcard/Music',
      'music': '/sdcard/Music',
      'الفيديو': '/sdcard/Movies',
      'فيديوهات': '/sdcard/Movies',
      'movies': '/sdcard/Movies',
      'واتساب': '/sdcard/WhatsApp',
      'whatsapp': '/sdcard/WhatsApp',
      'تيليجرام': '/sdcard/Telegram',
      'telegram': '/sdcard/Telegram',
      'الجذر': '/',
      'root': '/',
      'sdcard': '/sdcard',
      'الذاكرة': '/sdcard',
    };
    for (final entry in map.entries) {
      if (n.contains(DeviceKnowledgeService.normalizeArabic(entry.key).toLowerCase())) {
        return entry.value;
      }
    }
    return null;
  }

  // ═══════════════════════════════════════════
  //  واجهة التطبيق المفتوح
  // ═══════════════════════════════════════════

  /// النقر على عنصر: «اضغط على زر موافق».
  static _ParsedAction? _matchUiClick(String text) {
    final m = RegExp(
      r'(اضغط|انقر|دوس|كبس|كلك|click|tap)\s+(?:علي|على|فوق)?\s*(?:زر\s+|الزر\s+)?(.+)$',
    ).firstMatch(text);
    if (m == null) return null;
    final target = m.group(2)!.trim();
    if (target.isEmpty) return null;
    // «اضغط على الشاشة عند 500 600» → نقرة إحداثيات
    final coords = RegExp(r'(\d{1,5})\s+(\d{1,5})').firstMatch(target);
    if (coords != null) {
      return _ParsedAction(
        actionType: AgentActionTypes.inputTap,
        category: ActionCategory.automation,
        parameters: <String, dynamic>{
          'x': int.tryParse(coords.group(1)!) ?? 0,
          'y': int.tryParse(coords.group(2)!) ?? 0,
        },
      );
    }
    return _ParsedAction(
      actionType: AgentActionTypes.uiClick,
      category: ActionCategory.automation,
      parameters: <String, dynamic>{'text': target},
    );
  }

  /// الكتابة في حقل: «اكتب في خانة البحث كذا».
  static _ParsedAction? _matchUiSetText(String text) {
    final m = RegExp(
      r'(اكتب|كتب|ادخل|أدخل|املأ|املء|type|write)\s+(?:في\s+)?(?:خانة|حقل|مربع|خانت)?\s*(.+?)\s*[:\-]\s*(.+)$',
    ).firstMatch(text);
    if (m == null) {
      // صيغة مختصرة: «اكتب كذا» → كتابة مباشرة في الحقل المركز
      final simple = RegExp(r'^(اكتب|كتب|type|write)\s+(.+)$').firstMatch(text);
      if (simple == null) return null;
      final value = simple.group(2)!.trim();
      if (value.isEmpty) return null;
      return _ParsedAction(
        actionType: AgentActionTypes.inputText,
        category: ActionCategory.automation,
        parameters: <String, dynamic>{'text': value},
      );
    }
    final field = m.group(2)!.trim();
    final value = m.group(3)!.trim();
    if (value.isEmpty) return null;
    return _ParsedAction(
      actionType: AgentActionTypes.uiSetText,
      category: ActionCategory.automation,
      parameters: <String, dynamic>{'text': field, 'value': value},
    );
  }

  /// فتح تطبيق: «افتح واتساب» — المطابقة الأكثر عمومية، دائماً أخيراً.
  static _ParsedAction? _matchOpenApp(String text) {
    final m = RegExp(
      r'(?:افتح|شغل|فتح|open|launch|ابدأ|ابدا)\s+(?:تطبيق\s+|برنامج\s+)?(.+)$',
    ).firstMatch(text);
    if (m == null) return null;

    final appName = _cleanAppName(m.group(1)!);
    if (appName.isEmpty) return null;
    if (_isNotAnApp(appName)) return null;

    final package = _resolvePackage(appName);
    return _ParsedAction(
      actionType: AgentActionTypes.openApp,
      category: ActionCategory.system,
      targetApp: appName,
      parameters: <String, dynamic>{
        'appName': appName,
        if (package != null) 'packageName': package,
      },
    );
  }

  /// أسماء تُشبه اسم تطبيق لكنها ليست كذلك — تمنع التطابق الخاطئ.
  static bool _isNotAnApp(String name) {
    final n = DeviceKnowledgeService.normalizeArabic(name).toLowerCase();
    return RegExp(
      r'^(بيانات|النت|نت|انترنت|الانترنت|داتا|wifi|الشبكه|الشبكه اللاسلكيه|'
      r'البلوتوث|bluetooth|الكشاف|الفلاش|الشاشه|الصوت|الاعدادات العامه|'
      r'وضع الطيران|التنزيلات|التحميلات|الصور|المستندات|الموسيقى|الفيديو|'
      r'الجوال|الهاتف|البطاريه|التخزين|المساحه)$',
    ).hasMatch(n);
  }

  /// تنظيف اسم التطبيق من اللواحق العربية الشائعة.
  static String _cleanAppName(String raw) {
    var s = raw.trim();
    s = s.replaceAll(
      RegExp(r'\s+(اللي|الي|الذي|بتاع|بتاعه|مالي|حقي|عندي|الخاص|الخاصه|من فضلك)$'),
      '',
    );
    s = s.replaceAll(RegExp(r'[.!؟?,،]+$'), '');
    return s.trim();
  }

  // ═══════════════════════════════════════════
  //  أدوات التحليل
  // ═══════════════════════════════════════════

  /// استخراج نسبة مئوية: «50%»، «خمسين بالمئة»، «للنص».
  static int? _extractPercent(String text) {
    final m = RegExp(r'(\d{1,3})\s*(?:%|بالمئه|بالمئة|في المئه)').firstMatch(text);
    if (m != null) {
      final v = int.tryParse(m.group(1)!) ?? -1;
      if (v >= 0 && v <= 100) return v;
    }
    // «على 50» بعد كلمة السطوع/الصوت
    final m2 = RegExp(r'(?:علي|على)\s*(\d{1,3})(?!\d)').firstMatch(text);
    if (m2 != null) {
      final v = int.tryParse(m2.group(1)!) ?? -1;
      if (v >= 0 && v <= 100) return v;
    }
    const words = <String, int>{
      'صفر': 0, 'عشره': 10, 'عشرة': 10, 'عشرين': 20, 'ربع': 25,
      'تلاتين': 30, 'ثلاثين': 30, 'اربعين': 40, 'نص': 50, 'نصف': 50,
      'ستين': 60, 'سبعين': 70, 'تمانين': 80, 'ثمانين': 80, 'تسعين': 90,
      'ميه': 100, 'مئه': 100, 'كامل': 100, 'اقصي': 100, 'اقصی': 100,
    };
    for (final e in words.entries) {
      if (RegExp('(^|\\s)${e.key}(\\s|\$)').hasMatch(text)) return e.value;
    }
    return null;
  }

  /// تطبيع النص العربي: أرقام هندية → غربية، توحيد الهمزات، إزالة التشكيل.
  static String _normalize(String input) {
    var t = input.trim();

    const eastern = '٠١٢٣٤٥٦٧٨٩۰۱۲۳۴۵۶۷۸۹';
    for (var i = 0; i < 10; i++) {
      t = t.replaceAll(eastern[i], '$i');
    }

    t = t
        .replaceAll('أ', 'ا')
        .replaceAll('إ', 'ا')
        .replaceAll('آ', 'ا')
        .replaceAll('ة', 'ه');

    t = t.replaceAll(RegExp(r'[\u064B-\u0652\u0670\u0640]'), '');

    t = t.replaceAllMapped(
      RegExp(r'(?:ال)?واي\s*فاي|wifi|wi-fi', caseSensitive: false),
      (m) => 'wifi',
    );

    t = t.replaceAll(RegExp(r'\s+'), ' ');
    return t;
  }

  /// منشئ Regex يطبّع **النمط** بنفس دالة تطبيع نص المستخدم.
  ///
  /// السبب: نص المستخدم يُطبَّع دائماً (ة→ه، توحيد الهمزات…) قبل المطابقة،
  /// فإذا كُتب النمط بصيغة مختلفة اختلافاً دقيقاً (ة بدل ه) فشل التطابق
  /// بصمت. بتطبيع النمط نفسه نضمن تطابق الصيغتين دائماً.
  static RegExp nr(String pattern, {bool ci = false}) => RegExp(
        DeviceKnowledgeService.normalizeArabic(pattern),
        caseSensitive: !ci,
      );

  /// كلمات التفعيل/التعطيل — تعيد null عند الغموض.
  static bool? _detectEnable(String text) {
    final disable = RegExp(
      r'(اطفي|اطفا|اطفئ|طفي|اقفل|قفل|عطل|تعطيل|وقف|ايقاف|اسكت|افصل|off|close|disconnect)',
      caseSensitive: false,
    );
    if (disable.hasMatch(text)) return false;

    final enable = RegExp(
      r'(شغل|تشغيل|فعل|تفعيل|افتح|اشتغل|وصل|وصّل|نور|ولع|on|connect|enable)',
      caseSensitive: false,
    );
    if (enable.hasMatch(text)) return true;

    return null;
  }

  /// استخراج وقت الجدولة: «بعد 5 دقائق»، «بعد نصف ساعة»، «الساعة 9:30 مساءً».
  static _ScheduleExtraction _extractSchedule(String text) {
    var remaining = text;
    DateTime? time;
    final now = DateTime.now();

    final rel = RegExp(
      r'بعد\s+(\d+)\s*(ثانيه|ثواني|ثوان|دقيقه|دقائق|دقايق|ساعه|ساعات|يوم|ايام|اسبوع|اسبوعين|شهر)',
    ).firstMatch(remaining);

    final relWord = RegExp(
      r'بعد\s+(نص|نصف)\s+ساعه|بعد\s+(ساعتين)|بعد\s+ربع\s+ساعه|بعد\s+(ساعه)|بعد\s+(يوم)|بعد\s+(دقيقه)',
    ).firstMatch(remaining);

    final clock = RegExp(
      r'(?:في\s+)?(?:الساعه|ساعه)\s*(\d{1,2})(?::(\d{2}))?\s*(صباحا|صباح|فجرا|مساء|مساءا|مسا|مسانا|عصرا|عصر|مغرب|مغربا|ليلا|الليل)?',
    ).firstMatch(remaining);
    final tomorrow = RegExp(r'(غدا|بكره|بكرا|باكر|الغد)').hasMatch(remaining);

    if (rel != null) {
      final n = int.tryParse(rel.group(1)!) ?? 0;
      final unit = rel.group(2)!;
      final duration = switch (unit) {
        'ثانيه' || 'ثواني' || 'ثوان' => Duration(seconds: n),
        'دقيقه' || 'دقائق' || 'دقايق' => Duration(minutes: n),
        'ساعه' || 'ساعات' => Duration(hours: n),
        'يوم' || 'ايام' => Duration(days: n),
        'اسبوع' || 'اسبوعين' => Duration(days: n * 7),
        'شهر' => const Duration(days: 30),
        _ => Duration.zero,
      };
      time = now.add(duration);
      remaining = remaining.replaceRange(rel.start, rel.end, ' ');
    } else if (relWord != null) {
      final w = relWord.group(0)!;
      final duration = w.contains('نص') || w.contains('نصف')
          ? const Duration(minutes: 30)
          : w.contains('ربع')
              ? const Duration(minutes: 15)
              : w.contains('دقيقه')
                  ? const Duration(minutes: 1)
                  : w.contains('ساعتين')
                      ? const Duration(hours: 2)
                      : w.contains('يوم')
                          ? const Duration(days: 1)
                          : const Duration(hours: 1);
      time = now.add(duration);
      remaining = remaining.replaceRange(relWord.start, relWord.end, ' ');
    } else if (clock != null) {
      var hour = int.tryParse(clock.group(1)!) ?? 0;
      final minute = int.tryParse(clock.group(2) ?? '0') ?? 0;
      final meridiem = clock.group(3);

      final isEvening =
          RegExp('(مساء|مساءا|مسا|مسانا|عصرا|عصر|مغرب|مغربا|ليلا|الليل)')
                  .hasMatch(meridiem ?? '') &&
              hour < 12;
      if (isEvening) hour += 12;
      if (RegExp('(صباحا|صباح|فجرا)').hasMatch(meridiem ?? '') && hour == 12) {
        hour = 0;
      }

      var date = DateTime(now.year, now.month, now.day, hour, minute);
      if (tomorrow || date.isBefore(now)) {
        date = date.add(const Duration(days: 1));
      }
      time = date;
      remaining = remaining.replaceRange(clock.start, clock.end, ' ');
      remaining = remaining.replaceAll(RegExp(r'(غدا|بكره|بكرا|باكر|الغد)'), ' ');
    }

    return _ScheduleExtraction(
      time,
      remaining.replaceAll(RegExp(r'\s+'), ' ').trim(),
    );
  }

  /// استخراج رقم هاتف (7 أرقام فأكثر مع دعم +).
  static String? _extractPhoneNumber(String text) {
    final m = RegExp(r'(\+?\d[\d\s\-]{5,13}\d)').firstMatch(text)?.group(1);
    if (m == null) return null;
    final digits = m.replaceAll(RegExp(r'[\s\-]'), '');
    if (digits.replaceAll(RegExp(r'\D'), '').length < 7) return null;
    return digits;
  }

  static AgentActionIntent _build(
    String rawText,
    _ParsedAction action,
    DateTime? scheduledTime,
  ) {
    return AgentActionIntent(
      id: 'intent_${DateTime.now().microsecondsSinceEpoch}',
      rawText: rawText,
      actionType: action.actionType,
      category: action.category,
      targetApp: action.targetApp,
      parameters: action.parameters,
      scheduledTime: scheduledTime,
      requiresConfirmation: action.requiresConfirmation,
    );
  }

  // ═══════════════════════════════════════════
  //  2) المحلل السحابي الاحتياطي (Gemini REST)
  // ═══════════════════════════════════════════

  /// تحويل أمر معقد إلى JSON مهيكل عبر Gemini REST — يعيد null عند الفشل.
  ///
  /// ⚠️ هذا المسار احتياطي: المسار الأساسي هو [GeminiService.processVoiceCommand]
  /// الذي يدعم كل المزودين (Groq/OpenRouter/OpenAI/DeepSeek/Gemini) ويحقن
  /// جرد التطبيقات. تبقى هذه الدالة للتوافق مع الاستدعاءات القديمة.
  static Future<AgentActionIntent?> parseWithGemini(
    String rawText, {
    String? apiKey,
    String model = 'gemini-flash-latest',
  }) async {
    final key = apiKey ?? const String.fromEnvironment('GEMINI_API_KEY');
    if (key.isEmpty) return null;

    HttpClient? client;
    try {
      final uri = Uri.parse(
        'https://generativelanguage.googleapis.com/v1beta/models/'
        '$model:generateContent',
      );

      final body = jsonEncode(<String, dynamic>{
        'system_instruction': {
          'parts': [
            {'text': _geminiSystemPrompt}
          ]
        },
        'contents': [
          {
            'role': 'user',
            'parts': [
              {'text': rawText}
            ]
          }
        ],
        'generationConfig': <String, dynamic>{
          'temperature': 0.1,
          'responseMimeType': 'application/json',
        },
      });

      client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
      final request = await client.postUrl(uri);
      request.headers.contentType = ContentType.json;
      // ⚠️ Gemini يستخدم x-goog-api-key لا Authorization: Bearer
      request.headers.set('x-goog-api-key', key);
      request.write(body);
      final response =
          await request.close().timeout(const Duration(seconds: 20));
      final responseBody = await response.transform(utf8.decoder).join();

      if (response.statusCode != 200) return null;

      final data = jsonDecode(responseBody) as Map<String, dynamic>;
      final raw = data['candidates']?[0]?['content']?['parts']?[0]?['text'];
      if (raw is! String || raw.trim().isEmpty) return null;

      var cleaned = raw.trim();
      cleaned = cleaned.replaceAll(RegExp(r'^```(?:json)?\s*'), '');
      cleaned = cleaned.replaceAll(RegExp(r'\s*```$'), '');

      final map = jsonDecode(cleaned);
      if (map is! Map<String, dynamic>) return null;
      if (!AgentActionTypes.isKnown(map['actionType'] as String? ?? '')) {
        return null;
      }

      map['rawText'] = rawText;
      return AgentActionIntent.fromJson(map);
    } catch (_) {
      return null;
    } finally {
      client?.close(force: true);
    }
  }

  static const String _geminiSystemPrompt = '''
أنت محرك يحوّل أوامر المستخدم العربية إلى JSON مهيكل.
أعد فقط كائن JSON صالحاً بدون أي نص إضافي، بالبنية التالية:
{
  "actionType": "toggle_wifi | toggle_mobile_data | toggle_bluetooth | toggle_airplane | toggle_flashlight | set_brightness | set_volume | open_app | app_info | uninstall_app | force_stop_app | clear_app_cache | app_files | list_apps | list_files | find_file | battery_info | storage_info | device_info | media_control | navigate_ui | screenshot | lock_screen | call | send_message | open_url | search_web | open_camera | input_tap | input_text | ui_click | ui_set_text | payment | shell_command",
  "category": "system | automation | scheduler | payment | call | apps | files | device | media | messaging | info",
  "targetApp": "اسم التطبيق أو المحفظة أو null",
  "parameters": { "enable": true, "percent": 50, "phoneNumber": "712345678", "slotIndex": 1, "packageName": "com.example", "command": "...", "amount": 5000, "text": "...", "value": "...", "viewId": "...", "x": 540, "y": 1200, "path": "/sdcard/Download", "query": "...", "op": "pause", "target": "back" },
  "scheduledTime": "ISO8601 أو null إذا كان الأمر فورياً",
  "requiresConfirmation": false
}
قواعد: requiresConfirmation=true للعمليات المالية والهدّامة. slotIndex مبني على الصفر.
أمثلة:
"شغل الواي فاي" → {"actionType":"toggle_wifi","category":"system","targetApp":null,"parameters":{"enable":true},"scheduledTime":null,"requiresConfirmation":false}
"بعد نصف ساعة اطفي البيانات" → {"actionType":"toggle_mobile_data","category":"system","targetApp":null,"parameters":{"enable":false},"scheduledTime":"<بعد 30 دقيقة بصيغة ISO8601>","requiresConfirmation":false}
"نور الكشاف" → {"actionType":"toggle_flashlight","category":"system","targetApp":null,"parameters":{"enable":true},"scheduledTime":null,"requiresConfirmation":false}
''';

  // ═══════════════════════════════════════════
  //  خرائط التطبيقات والمحافظ (احتياط)
  // ═══════════════════════════════════════════

  /// الخريطة المكتوبة يدوياً — **احتياط فقط**.
  ///
  /// المسار الأساسي هو [DeviceKnowledgeService.resolvePackage] الذي يقرأ
  /// التطبيقات المثبتة فعلياً على جهاز المستخدم. تبقى هذه الخريطة
  /// للأسماء العربية الدارجة التي لا يطابقها PackageManager بالاسم
  /// (مثل «المتصفح» → كروم) وللعمل عندما تتعذر القناة الأصلية.
  static const Map<String, String> _appPackages = <String, String>{
    // تطبيقات شائعة
    'واتساب': 'com.whatsapp',
    'واتس اب': 'com.whatsapp',
    'whatsapp': 'com.whatsapp',
    'تيليجرام': 'org.telegram.messenger',
    'تلجرام': 'org.telegram.messenger',
    'telegram': 'org.telegram.messenger',
    'يوتيوب': 'com.google.android.youtube',
    'youtube': 'com.google.android.youtube',
    'انستقرام': 'com.instagram.android',
    'انستا': 'com.instagram.android',
    'instagram': 'com.instagram.android',
    'فيسبوك': 'com.facebook.katana',
    'facebook': 'com.facebook.katana',
    'تيك توك': 'com.zhiliaoapp.musically',
    'تيكتوك': 'com.zhiliaoapp.musically',
    'tiktok': 'com.zhiliaoapp.musically',
    'كروم': 'com.android.chrome',
    'chrome': 'com.android.chrome',
    'المتصفح': 'com.android.chrome',
    'الاعدادات': 'com.android.settings',
    'settings': 'com.android.settings',
    'الهاتف': 'com.android.dialer',
    'الاتصالات': 'com.android.dialer',
    'الرسائل': 'com.google.android.apps.messaging',
    'الرسايل': 'com.google.android.apps.messaging',
    'الكاميرا': 'com.android.camera2',
    'كاميرا': 'com.android.camera2',
    'الساعه': 'com.android.deskclock',
    'منبه': 'com.android.deskclock',
    'الحاسبه': 'com.android.calculator2',
    'الملفات': 'com.android.documentsui',
    'المعرض': 'com.android.gallery3d',
    'الصور': 'com.android.gallery3d',
    'خرائط': 'com.google.android.apps.maps',
    'جيمنياي': 'com.google.android.apps.maps',

    // محافظ وبنوك يمنية (⚠️ تحقق من الحزم الفعلية على جهازك —
    // المسار الأساسي الآن يقرأها من PackageManager مباشرة)
    'جوادي': 'com.jawadi.wallet',
    'جوايدي': 'com.jawadi.wallet',
    'كرمي': 'com.kuraimi.app',
    'يمن كاش': 'com.yemencash.app',
    'ون كاش': 'com.onecash.app',
    'موبايل موني': 'com.mobilemoney.app',
  };

  static const List<String> _knownWallets = <String>[
    'جوادي', 'جوايدي', 'كرمي', 'كرمي كاش', 'يمن كاش',
    'ون كاش', 'موبايل موني', 'محفظه موبايل', 'محفظتي',
  ];

  /// بحث في الخريطة الاحتياطية (متطابق + بلا مسافات + تطبيع).
  static String? _resolvePackage(String appName) {
    final key = DeviceKnowledgeService.normalizeArabic(appName).trim();
    if (key.isEmpty) return null;
    final direct = _appPackages[key] ?? _appPackages[key.replaceAll(' ', '')];
    if (direct != null) return direct;
    for (final entry in _appPackages.entries) {
      if (DeviceKnowledgeService.normalizeArabic(entry.key) == key) {
        return entry.value;
      }
    }
    return null;
  }
}

/// نتيجة التحليل المحلي — الأمر + وقت الجدولة.
class _LocalParseResult {
  const _LocalParseResult(this.action, this.scheduleTime);

  final _ParsedAction action;
  final DateTime? scheduleTime;
}
