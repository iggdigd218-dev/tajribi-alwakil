import 'dart:convert';
import 'dart:io';

import '../models/agent_action_intent.dart';
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

/// محرك تحليل الأوامر الهجين (المرحلة 4):
///
/// 1. محلل محلي فوري (Rule-Based / Regex) عالي الدقة للأوامر
///    الشائعة — يعمل بالكامل دون إنترنت.
/// 2. ربط سحابي اختياري بـ Gemini API لتحويل الأوامر المعقدة إلى
///    JSON مهيكل يطابق AgentActionIntent (يُستدعى فقط عند فشل
///    المحلل المحلي وتوفر المفتاح).
class IntentParserService {
  IntentParserService._();

  // ═══════════════════════════════════════════
  //  1) المحلل المحلي (Offline First)
  // ═══════════════════════════════════════════

  /// تحليل فوري بدون إنترنت — يعيد null إذا لم يفهم الأمر.
  /// الاسم المستقر الذي تستدعيه الواجهة: [parseLocal].
  static AgentActionIntent? parseLocal(String rawText) => parse(rawText);

  /// تحليل فوري بدون إنترنت — يعيد null إذا لم يفهم الأمر.
  static AgentActionIntent? parse(String rawText) {
    if (rawText.trim().isEmpty) return null;

    final text = _normalize(rawText);

    // (أ) استخراج وقت الجدولة أولاً — "بعد 5 دقائق"، "الساعة 9 مساءً"
    final schedule = _extractSchedule(text);
    var working = schedule.remaining;

    // (ب) أمر Shell صريح: "نفذ: svc data enable"
    final shell =
        RegExp(r'^(?:نفذ|تنفيذ|امر|شل)\s*[:\-]?\s*(.+)$').firstMatch(working);
    if (shell != null) {
      return _build(
        rawText,
        _ParsedAction(
          actionType: AgentActionTypes.shellCommand,
          category: ActionCategory.system,
          parameters: {'command': shell.group(1)!},
        ),
        schedule.time,
      );
    }

    // (ج) الدفع والتحويل المالي — "افتح محفظة جوادي"، "حول 5000 ريال"
    final payment = _matchPayment(working);
    if (payment != null) return _build(rawText, payment, schedule.time);

    // (د) الاتصال وتحديد الشريحة — "اتصل بـ 712345678 من الشريحة 2"
    final call = _matchCall(working);
    if (call != null) return _build(rawText, call, schedule.time);

    // (هـ) الشبكة — "شغل الواي فاي"، "اطفئ البيانات"
    final network = _matchNetwork(working);
    if (network != null) return _build(rawText, network, schedule.time);

    // (و) فتح تطبيق — "افتح واتساب"
    final app = _matchOpenApp(working);
    if (app != null) return _build(rawText, app, schedule.time);

    return null;
  }

  /// المحلل الهجين: محلي أولاً، ثم Gemini للأوامر المعقدة.
  /// المفتاح: الوسيط الصريح، وإلا [GeminiService.apiKey]
  /// (المفتاح البرمجي المحفوظ من الإعدادات يتقدم على --dart-define).
  static Future<AgentActionIntent?> parseSmart(
    String rawText, {
    String? geminiApiKey,
  }) async {
    final local = parseLocal(rawText);
    if (local != null) return local;

    final key = (geminiApiKey != null && geminiApiKey.trim().isNotEmpty)
        ? geminiApiKey.trim()
        : GeminiService.apiKey;
    if (key.isEmpty) return null;

    return parseWithGemini(rawText, apiKey: key);
  }

  // ═══════════════════════════════════════════
  //  2) المحلل السحابي الاختياري (Gemini API)
  // ═══════════════════════════════════════════

  /// تحويل أمر معقد إلى JSON مهيكل عبر Gemini — يعيد null عند الفشل.
  /// يعتمد على dart:io HttpClient (بدون أي حزم خارجية).
  static Future<AgentActionIntent?> parseWithGemini(
    String rawText, {
    String? apiKey,
    String model = 'gemini-1.5-flash',
  }) async {
    final key = apiKey ?? const String.fromEnvironment('GEMINI_API_KEY');
    if (key.isEmpty) return null;

    HttpClient? client;
    try {
      final uri = Uri.parse(
        'https://generativelanguage.googleapis.com/v1/models/'
        '$model:generateContent?key=$key',
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
        'generationConfig': {
          'temperature': 0.1,
          'responseMimeType': 'application/json',
        },
      });

      client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
      final request = await client.postUrl(uri);
      request.headers.contentType = ContentType.json;
      request.write(body);
      final response = await request.close().timeout(const Duration(seconds: 20));
      final responseBody = await response.transform(utf8.decoder).join();

      if (response.statusCode != 200) return null;

      final data = jsonDecode(responseBody) as Map<String, dynamic>;
      final raw = data['candidates']?[0]?['content']?['parts']?[0]?['text'];
      if (raw is! String || raw.trim().isEmpty) return null;

      // تنظيف أسوار code fences إن وُجدت
      var cleaned = raw.trim();
      cleaned = cleaned.replaceAll(RegExp(r'^```(?:json)?\s*'), '');
      cleaned = cleaned.replaceAll(RegExp(r'\s*```$'), '');

      final map = jsonDecode(cleaned);
      if (map is! Map<String, dynamic>) return null;

      map['rawText'] = rawText;
      return AgentActionIntent.fromJson(map);
    } catch (_) {
      return null; // فشل صامت — العودة للمستوى الأعلى
    } finally {
      client?.close();
    }
  }

  static const String _geminiSystemPrompt = '''
أنت محرك يحوّل أوامر المستخدم العربية إلى JSON مهيكل.
أعد فقط كائن JSON صالحاً بدون أي نص إضافي، بالبنية التالية:
{
  "actionType": "toggle_wifi | toggle_mobile_data | open_app | call | shell_command | input_tap | input_text | ui_click | ui_set_text | payment",
  "category": "system | automation | scheduler | payment | call",
  "targetApp": "اسم التطبيق أو المحفظة أو null",
  "parameters": { "enable": true, "phoneNumber": "712345678", "slotIndex": 1, "packageName": "com.example", "command": "...", "amount": 5000, "text": "...", "viewId": "...", "x": 540, "y": 1200 },
  "scheduledTime": "ISO8601 أو null إذا كان الأمر فورياً",
  "requiresConfirmation": false
}
قواعد: requiresConfirmation=true فقط للعمليات المالية. slotIndex مبني على الصفر (الشريحة 1 = 0، الشريحة 2 = 1).
أمثلة:
"شغل الواي فاي" → {"actionType":"toggle_wifi","category":"system","targetApp":null,"parameters":{"enable":true},"scheduledTime":null,"requiresConfirmation":false}
"بعد نصف ساعة اطفي البيانات" → {"actionType":"toggle_mobile_data","category":"system","targetApp":null,"parameters":{"enable":false},"scheduledTime":"<بعد 30 دقيقة من الآن بصيغة ISO8601>","requiresConfirmation":false}
''';

  // ═══════════════════════════════════════════
  //  مطابقات الأوامر المحلية
  // ═══════════════════════════════════════════

  /// الدفع والتحويل: "حول 5000 ريال من محفظة جوادي"، "افتح محفظة كذا".
  static _ParsedAction? _matchPayment(String text) {
    final hasWallet = RegExp(
      r'(محفظه|وايت|كاش|موبايل موني|جوايدي|جوادي|كرمي|يمن كاش|ون كاش|بنك)',
    ).hasMatch(text);
    if (!hasWallet) return null;

    final isTransfer =
        RegExp(r'(حول|تحويل|حواله|ادفع|دفع|ارسل|سدد)').hasMatch(text);
    final isOpen = RegExp(r'(افتح|شغل|فتح)').hasMatch(text);
    if (!isTransfer && !isOpen) return null;

    // اسم المحفظة: الكلمة التالية لـ "محفظة" أو اسم معروف
    var walletName = _knownWallets
        .firstWhere((w) => text.contains(w), orElse: () => '');
    final walletAfterWord =
        RegExp(r'(?:محفظه|وايت)\s+(\S+)').firstMatch(text)?.group(1);
    if (walletName.isEmpty && walletAfterWord != null) {
      walletName = walletAfterWord;
    }
    if (walletName.isEmpty) walletName = 'المحفظة';

    final parameters = <String, dynamic>{
      'walletName': walletName,
    };

    // المبلغ: أول رقم في النص
    final amount =
        RegExp(r'(\d+(?:\.\d+)?)').firstMatch(text)?.group(1);
    if (amount != null) parameters['amount'] = num.tryParse(amount);

    // رقم المستلم إن وُجد
    final phone = _extractPhoneNumber(text);
    if (phone != null) parameters['phoneNumber'] = phone;

    // معرّف الحزمة إن كان معروفاً
    final package = _resolvePackage(walletName);
    if (package != null) parameters['packageName'] = package;

    if (isTransfer) {
      // عملية مالية حساسة → تتطلب تأكيداً صريحاً
      return _ParsedAction(
        actionType: AgentActionTypes.payment,
        category: ActionCategory.payment,
        targetApp: walletName,
        parameters: parameters,
        requiresConfirmation: true,
      );
    }

    // مجرد فتح المحفظة — لا يتطلب تأكيداً
    return _ParsedAction(
      actionType: AgentActionTypes.openApp,
      category: ActionCategory.payment,
      targetApp: walletName,
      parameters: parameters,
    );
  }

  /// الاتصال: "اتصل بـ 712345678 من الشريحة 2".
  static _ParsedAction? _matchCall(String text) {
    if (!RegExp(r'(اتصل|اتصال|كلم|مكالمه|يرن)').hasMatch(text)) return null;

    // تحديد الشريحة: "من الشريحة 2" / "شريحة 2" / "سم 2" / "sim 2"
    var slotIndex = 0;
    final slot = RegExp(
      r'(?:الشريحه|شريحه|الخط|سم|سيم|sim)\s*(\d)',
      caseSensitive: false,
    ).firstMatch(text);
    if (slot != null) {
      slotIndex = (int.tryParse(slot.group(1)!) ?? 1) - 1; // 0-based
      if (slotIndex < 0) slotIndex = 0;
    }

    // استخراج الرقم — ملاحظة: "اتصل بأحمد" بدون رقم لا يمكن حله محلياً
    // (يتطلب دفتر جهات الاتصال) ويُحوَّل تلقائياً للمحلل السحابي.
    final phone = _extractPhoneNumber(text);
    if (phone == null) return null;

    return _ParsedAction(
      actionType: AgentActionTypes.call,
      category: ActionCategory.call,
      parameters: {'phoneNumber': phone, 'slotIndex': slotIndex},
    );
  }

  /// الشبكة: "شغل الواي فاي"، "اطفئ البيانات".
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

    final enable = _detectEnable(text);
    if (enable == null) return null;

    // إن ذُكر الهاتف/البيانات صراحةً فهي أولوية
    final preferData = isData &&
        (!isWifi || RegExp(r'(هاتف|جوال|بيانات|انترنت|نت)').hasMatch(text));

    if (preferData) {
      return _ParsedAction(
        actionType: AgentActionTypes.toggleMobileData,
        category: ActionCategory.system,
        parameters: {'enable': enable},
      );
    }
    return _ParsedAction(
      actionType: AgentActionTypes.toggleWifi,
      category: ActionCategory.system,
      parameters: {'enable': enable},
    );
  }

  /// فتح تطبيق: "افتح واتساب".
  static _ParsedAction? _matchOpenApp(String text) {
    final m = RegExp(
      r'(?:افتح|شغل|فتح|open)\s+(?:تطبيق\s+|برنامج\s+)?(.+)$',
    ).firstMatch(text);
    if (m == null) return null;

    final appName = m.group(1)!.trim();
    // كلمات سبقت معالجتها (شبكة/بيانات/محفظة) — لا تعالج كتطبيق
    if (RegExp(
      r'^(بيانات|النت|نت|انترنت|الانترنت|داتا|wifi|الشبكه|الشبكه اللاسلكيه)$',
      caseSensitive: false,
    ).hasMatch(appName)) {
      return null;
    }

    return _ParsedAction(
      actionType: AgentActionTypes.openApp,
      category: ActionCategory.system,
      targetApp: appName,
      parameters: {
        'appName': appName,
        if (_resolvePackage(appName) != null)
          'packageName': _resolvePackage(appName)!,
      },
    );
  }

  // ═══════════════════════════════════════════
  //  أدوات التحليل
  // ═══════════════════════════════════════════

  /// تطبيع النص العربي: أرقام عربية-هندية → غربية، توحيد الهمزات،
  /// إزالة التشكيل والتطويل، توحيد "واي فاي" → wifi.
  static String _normalize(String input) {
    var t = input.trim();

    // ٠١٢٣٤٥٦٧٨٩ (عربية-هندية) و ۰۱۲۳۴۵۶۷۸۹ (فارسية) → 0-9
    const eastern = '٠١٢٣٤٥٦٧٨٩۰۱۲۳۴۵۶۷۸۹';
    for (var i = 0; i < 10; i++) {
      t = t.replaceAll(eastern[i], '$i');
    }

    t = t
        .replaceAll('أ', 'ا')
        .replaceAll('إ', 'ا')
        .replaceAll('آ', 'ا')
        .replaceAll('ة', 'ه');

    // إزالة التشكيل والتطويل
    t = t.replaceAll(RegExp(r'[\u064B-\u0652\u0670\u0640]'), '');

    // توحيد صيغ الواي فاي
    t = t.replaceAllMapped(
      RegExp(r'(?:ال)?واي\s*فاي|wifi|wi-fi',
          caseSensitive: false),
      (m) => 'wifi',
    );

    // ضغط الفراغات
    t = t.replaceAll(RegExp(r'\s+'), ' ');

    return t;
  }

  /// كلمات التفعيل/التعطيل — تعيد null عند الغموض.
  static bool? _detectEnable(String text) {
    final disable = RegExp(
      r'(اطفي|اطفا|اطفئ|طفي|اقفل|قفل|عطل|تعطيل|وقف|ايقاف|اسكت|off|close|disconnect)',
      caseSensitive: false,
    );
    if (disable.hasMatch(text)) return false; // أولوية للتعطيل

    final enable = RegExp(
      r'(شغل|تشغيل|فعل|تفعيل|افتح|اشتغل|وصل|وصّل|on|connect)',
      caseSensitive: false,
    );
    if (enable.hasMatch(text)) return true;

    return null;
  }

  /// استخراج وقت الجدولة: "بعد 5 دقائق"، "بعد نصف ساعة"،
  /// "الساعة 9:30 مساءً"، "غدا الساعة 8 صباحاً".
  static _ScheduleExtraction _extractSchedule(String text) {
    var remaining = text;
    DateTime? time;
    final now = DateTime.now();

    // (1) بعد N وحدة زمنية
    final rel = RegExp(
      r'بعد\s+(\d+)\s*(ثانيه|ثواني|ثوان|دقيقه|دقائق|دقايق|ساعه|ساعات|يوم|ايام)',
    ).firstMatch(remaining);

    // (2) بعد <كمية كلامية>
    final relWord = RegExp(
      r'بعد\s+(نص|نصف)\s+ساعه|بعد\s+(ساعتين)|بعد\s+ربع\s+ساعه|بعد\s+(ساعه)|بعد\s+(يوم)',
    ).firstMatch(remaining);

    // (3) ساعة محددة: "الساعة 9" / "الساعة 9:30 مساءً" (+ غدا/بكرة)
    final clock = RegExp(
      r'(?:في\s+)?(?:الساعه|ساعه)\s*(\d{1,2})(?::(\d{2}))?\s*(صباحا|صباح|فجرا|مساء|مساءا|مسا|مسانا|عصرا|عصر|مغرب|مغربا|ليلا|الليل)?',
    ).firstMatch(remaining);
    final tomorrow =
        RegExp(r'(غدا|بكره|بكرا|باكر|الغد)').hasMatch(remaining);

    if (rel != null) {
      final n = int.tryParse(rel.group(1)!) ?? 0;
      final unit = rel.group(2)!;
      final duration = switch (unit) {
        'ثانيه' || 'ثواني' || 'ثوان' => Duration(seconds: n),
        'دقيقه' || 'دقائق' || 'دقايق' => Duration(minutes: n),
        'ساعه' || 'ساعات' => Duration(hours: n),
        'يوم' || 'ايام' => Duration(days: n),
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

      final isEvening = RegExp('(مساء|مساءا|مسا|مسانا|عصرا|عصر|مغرب|مغربا|ليلا|الليل)')
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
      remaining = remaining.replaceAll(
        RegExp(r'(غدا|بكره|بكرا|باكر|الغد)'),
        ' ',
      );
    }

    return _ScheduleExtraction(
      time,
      remaining.replaceAll(RegExp(r'\s+'), ' ').trim(),
    );
  }

  /// استخراج رقم هاتف (7 أرقام فأكثر مع دعم +).
  static String? _extractPhoneNumber(String text) {
    final m =
        RegExp(r'(\+?\d[\d\s\-]{5,13}\d)').firstMatch(text)?.group(1);
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
  //  خرائط التطبيقات والمحافظ
  // ═══════════════════════════════════════════

  static const List<String> _knownWallets = [
    'جوادي', 'جوايدي', 'كرمي', 'كرمي كاش', 'يمن كاش',
    'ون كاش', 'موبايل موني', 'محفظه موبايل',
  ];

  /// خريطة أسماء التطبيقات → معرّفات الحزم.
  ///
  /// ⚠️ معرّفات المحافظ/البنوك المحلية حزبية-placeholder — تحقق منها على
  /// جهازك عبر: `adb shell pm list packages | grep -i <اسم>` وحدّثها.
  static const Map<String, String> _appPackages = {
    // تطبيقات شائعة
    'واتساب': 'com.whatsapp',
    'واتس اب': 'com.whatsapp',
    'whatsapp': 'com.whatsapp',
    'تيليجرام': 'org.telegram.messenger',
    'تلجرام': 'org.telegram.messenger',
    'يوتيوب': 'com.google.android.youtube',
    'انستقرام': 'com.instagram.android',
    'انستا': 'com.instagram.android',
    'فيسبوك': 'com.facebook.katana',
    'كروم': 'com.android.chrome',
    'المتصفح': 'com.android.chrome',
    'الاعدادات': 'com.android.settings',
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

    // محافظ وبنوك يمنية (⚠️ تحقق من الحزم الفعلية على جهازك)
    'جوادي': 'com.jawadi.wallet',
    'جوايدي': 'com.jawadi.wallet',
    'كرمي': 'com.kuraimi.app',
    'يمن كاش': 'com.yemencash.app',
    'ون كاش': 'com.onecash.app',
    'موبايل موني': 'com.mobilemoney.app',
  };

  static String? _resolvePackage(String appName) {
    final key = appName.trim();
    return _appPackages[key] ?? _appPackages[key.replaceAll(' ', '')];
  }
}
