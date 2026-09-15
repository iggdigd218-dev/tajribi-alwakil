import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, debugPrint, TargetPlatform;
import 'package:flutter/services.dart';

/// تطبيق مثبّت على الجهاز كما يراه الوكيل.
class InstalledApp {
  const InstalledApp({
    required this.packageName,
    required this.appName,
    required this.isSystem,
    required this.enabled,
    required this.hasLauncher,
    this.versionName = '',
    this.versionCode = 0,
    this.installedAt = '',
    this.updatedAt = '',
    this.apkPath = '',
    this.dataDir = '',
    this.cacheDir = '',
    this.externalDir = '',
    this.sizeBytes = 0,
  });

  final String packageName;
  final String appName;
  final bool isSystem;
  final bool enabled;
  final bool hasLauncher;
  final String versionName;
  final int versionCode;
  final String installedAt;
  final String updatedAt;
  final String apkPath;
  final String dataDir;
  final String cacheDir;
  final String externalDir;
  final int sizeBytes;

  factory InstalledApp.fromMap(Map<dynamic, dynamic> m) => InstalledApp(
        packageName: (m['packageName'] as String?) ?? '',
        appName: (m['appName'] as String?) ?? '',
        isSystem: m['isSystem'] == true,
        enabled: m['enabled'] != false,
        hasLauncher: m['hasLauncher'] == true,
        versionName: (m['versionName'] as String?) ?? '',
        versionCode: (m['versionCode'] as num?)?.toInt() ?? 0,
        installedAt: (m['installedAt'] as String?) ?? '',
        updatedAt: (m['updatedAt'] as String?) ?? '',
        apkPath: (m['apkPath'] as String?) ?? '',
        dataDir: (m['dataDir'] as String?) ?? '',
        cacheDir: (m['cacheDir'] as String?) ?? '',
        externalDir: (m['externalDir'] as String?) ?? '',
        sizeBytes: (m['sizeBytes'] as num?)?.toInt() ?? 0,
      );

  Map<String, dynamic> toMap() => <String, dynamic>{
        'packageName': packageName,
        'appName': appName,
        'isSystem': isSystem,
        'enabled': enabled,
        'versionName': versionName,
        'sizeBytes': sizeBytes,
      };

  /// سطر موجز يُحقن في موجه الذكاء الاصطناعي (لا يُثقل السياق).
  String get promptLine => '$appName [$packageName]';

  @override
  String toString() => '$appName ($packageName)';
}

/// لقطة حيّة لحالة الجهاز — تُستخدم للرد الفوري دون إنترنت.
class DeviceSnapshot {
  const DeviceSnapshot(this.map);

  final Map<String, dynamic> map;

  factory DeviceSnapshot.fromMap(Map<dynamic, dynamic>? m) =>
      DeviceSnapshot(_cast(m));

  static Map<String, dynamic> _cast(Map<dynamic, dynamic>? m) =>
      m == null ? <String, dynamic>{} : m.cast<String, dynamic>();

  String get model => (map['model'] as String?) ?? 'جهاز غير معروف';
  String get manufacturer => (map['manufacturer'] as String?) ?? '';
  String get androidVersion => (map['androidVersion'] as String?) ?? '';
  int get sdkInt => (map['sdkInt'] as num?)?.toInt() ?? 0;
  int get batteryPercent => (map['batteryPercent'] as num?)?.toInt() ?? -1;
  bool get isCharging => map['isCharging'] == true;
  String get batteryHealth => (map['batteryHealth'] as String?) ?? '';
  int get storageTotalBytes => (map['storageTotalBytes'] as num?)?.toInt() ?? 0;
  int get storageFreeBytes => (map['storageFreeBytes'] as num?)?.toInt() ?? 0;
  int get storageUsedPercent =>
      (map['storageUsedPercent'] as num?)?.toInt() ?? 0;
  bool get shizukuRunning => map['shizukuRunning'] == true;
  bool get shizukuGranted => map['shizukuGranted'] == true;
  bool get accessibilityEnabled => map['accessibilityEnabled'] == true;
  bool get overlayPermission => map['overlayPermission'] == true;
  bool get exactAlarmAllowed => map['exactAlarmAllowed'] == true;
  bool get isDefaultAssistant => map['isDefaultAssistant'] == true;
  bool get foregroundServiceRunning => map['foregroundServiceRunning'] == true;
  String get currentTime => (map['currentTime'] as String?) ?? '';

  /// عدد التطبيقات (كلي/نظام/مستخدم).
  (int, int, int) get appCounts {
    final c = map['appCounts'];
    if (c is Map) {
      return (
        (c['total'] as num?)?.toInt() ?? 0,
        (c['system'] as num?)?.toInt() ?? 0,
        (c['user'] as num?)?.toInt() ?? 0,
      );
    }
    return (0, 0, 0);
  }

  /// ملخص عربي جاهز للنطق/العرض.
  String get arabicSummary {
    final (total, system, user) = appCounts;
    final parts = <String>[
      'الجهاز: $model',
      'أندرويد $androidVersion',
      if (batteryPercent >= 0)
        'البطارية: $batteryPercent%${isCharging ? " (تشحن)" : ""}',
      if (storageTotalBytes > 0)
        'التخزين: ${DeviceKnowledgeService.humanSize(storageFreeBytes)} '
            'متاحة من ${DeviceKnowledgeService.humanSize(storageTotalBytes)} '
            '(مستخدم $storageUsedPercent%)',
      'التطبيقات: $total ($user مثبتة، $system نظامية)',
      'إمكانية الوصول: ${accessibilityEnabled ? "مفعّلة" : "غير مفعّلة"}',
      'Shizuku: ${shizukuGranted ? "مفعّل ومرخّص" : shizukuRunning ? "يعمل لكن بلا ترخيص" : "غير مشغّل"}',
      'النافذة العائمة: ${overlayPermission ? "مرخّصة" : "غير مرخّصة"}',
      'التنبيهات الدقيقة: ${exactAlarmAllowed ? "مسموحة" : "غير مسموحة"}',
      'المساعد الافتراضي: ${isDefaultAssistant ? "نعم" : "لا"}',
    ];
    return parts.join('\n');
  }
}

/// معرفة الجهاز: التطبيقات المثبتة، ملفاتها، وحقائق الجهاز الحيّة.
///
/// تربط القناة الأصلية `com.example.app/device_knowledge`
/// (المسجّلة في DeviceKnowledgeBridge.kt).
///
/// تعمل **بدون إنترنت وبدون Shizuku** — كل ما يعتمد على PackageManager
/// متاح مباشرة؛ أما سرد محتوى مجلدات التطبيقات فيتطلب Shizuku ويُعاد
/// سبب التعذّر بدل الفشل الصامت.
class DeviceKnowledgeService {
  DeviceKnowledgeService._();

  static const MethodChannel _channel =
      MethodChannel('com.example.app/device_knowledge');

  static bool get _isAndroid =>
      defaultTargetPlatform == TargetPlatform.android;

  // ── ذاكرة مؤقتة في طبقة Dart أيضاً ──
  static List<InstalledApp>? _appsCache;
  static DateTime? _appsCacheTime;
  static DeviceSnapshot? _snapshotCache;
  static DateTime? _snapshotTime;

  static const Duration _appsTtl = Duration(minutes: 5);
  static const Duration _snapshotTtl = Duration(seconds: 15);

  /// إبطال الذاكرة المؤقتة (بعد تثبيت/إلغاء تطبيق مثلاً).
  static Future<void> invalidateCache() async {
    _appsCache = null;
    _appsCacheTime = null;
    _snapshotCache = null;
    _snapshotTime = null;
    if (_isAndroid) {
      try {
        await _channel.invokeMethod<bool>('invalidateCache');
      } on PlatformException catch (_) {}
      on MissingPluginException catch (_) {}
    }
  }

  /// لقطة حالة الجهاز.
  static Future<DeviceSnapshot> deviceSnapshot({bool force = false}) async {
    if (!_isAndroid) return const DeviceSnapshot(<String, dynamic>{});
    final cached = _snapshotCache;
    if (!force &&
        cached != null &&
        _snapshotTime != null &&
        DateTime.now().difference(_snapshotTime!) < _snapshotTtl) {
      return cached;
    }
    try {
      final map = await _channel.invokeMapMethod<String, dynamic>(
        'deviceSnapshot',
      );
      final snap = DeviceSnapshot.fromMap(map);
      _snapshotCache = snap;
      _snapshotTime = DateTime.now();
      return snap;
    } on PlatformException catch (e) {
      debugPrint('deviceSnapshot فشل: ${e.message}');
      return const DeviceSnapshot(<String, dynamic>{});
    } on MissingPluginException {
      return const DeviceSnapshot(<String, dynamic>{});
    }
  }

  /// كل التطبيقات المثبتة.
  ///
  /// [includeSystem] تضمين تطبيقات النظام.
  /// [withSizes] حساب الأحجام على القرص (بطيء — يستدعي مرة واحدة عند الحاجة).
  /// [force] تجاوز الذاكرة المؤقتة.
  static Future<List<InstalledApp>> listApps({
    bool includeSystem = false,
    bool withSizes = false,
    bool force = false,
  }) async {
    if (!_isAndroid) return const <InstalledApp>[];
    final cached = _appsCache;
    if (!force &&
        !withSizes &&
        cached != null &&
        _appsCacheTime != null &&
        DateTime.now().difference(_appsCacheTime!) < _appsTtl) {
      return includeSystem
          ? cached
          : cached.where((a) => !a.isSystem).toList(growable: false);
    }
    try {
      final raw = await _channel.invokeMethod<dynamic>('listApps', {
        'includeSystem': includeSystem,
        'withSizes': withSizes,
      });
      final list = (raw as List? ?? const <dynamic>[])
          .whereType<Map<dynamic, dynamic>>()
          .map(InstalledApp.fromMap)
          .toList(growable: false);
      if (includeSystem) {
        _appsCache = list;
        _appsCacheTime = DateTime.now();
      }
      return list;
    } on PlatformException catch (e) {
      debugPrint('listApps فشل: ${e.message}');
      return const <InstalledApp>[];
    } on MissingPluginException {
      return const <InstalledApp>[];
    }
  }

  /// بحث عن تطبيق بالاسم العربي أو الإنجليزي أو معرّف الحزمة.
  ///
  /// يعيد قائمة مرتّبة — تطبيقات المستخدم أولاً. فارغة إن لم يُوجد.
  static Future<List<InstalledApp>> findApp(String query) async {
    if (!_isAndroid || query.trim().isEmpty) return const <InstalledApp>[];
    try {
      final raw = await _channel.invokeMethod<dynamic>(
        'findApp',
        {'query': query.trim()},
      );
      return (raw as List? ?? const <dynamic>[])
          .whereType<Map<dynamic, dynamic>>()
          .map(InstalledApp.fromMap)
          .toList(growable: false);
    } on PlatformException catch (_) {
      return _findAppLocally(query);
    } on MissingPluginException {
      return _findAppLocally(query);
    }
  }

  /// بحث احتياطي في الذاكرة المحلية (إن تعذّرت القناة الأصلية).
  static Future<List<InstalledApp>> _findAppLocally(String query) async {
    final q = normalizeArabic(query);
    final apps = await listApps(includeSystem: true);
    final hits = apps.where((a) {
      final name = normalizeArabic(a.appName);
      final pkg = a.packageName.toLowerCase();
      return name == q ||
          name.contains(q) ||
          pkg.contains(q.toLowerCase()) ||
          pkg.split('.').any(
                (p) => p.length > 2 && q.toLowerCase().contains(p),
              );
    }).toList(growable: false)
      ..sort((a, b) => (a.isSystem ? 1 : 0).compareTo(b.isSystem ? 1 : 0));
    return hits.take(25).toList(growable: false);
  }

  /// حلّ اسم تطبيق (كما يقوله المستخدم) إلى معرّف حزمة فعلي على جهازه.
  ///
  /// يعيد null إن لم يُوجد تطابق — وعندها يقرر المستدعي بين السؤال أو
  /// تمرير الاسم للذكاء الاصطناعي.
  static Future<InstalledApp?> resolvePackage(String appName) async {
    final hits = await findApp(appName);
    return hits.isEmpty ? null : hits.first;
  }

  /// تفاصيل تطبيق واحد (صلاحياته، أنشطته، حجمه).
  static Future<Map<String, dynamic>?> appDetails(String packageName) async {
    if (!_isAndroid) return null;
    try {
      final m = await _channel.invokeMapMethod<String, dynamic>(
        'appDetails',
        {'packageName': packageName},
      );
      return m?.cast<String, dynamic>();
    } on PlatformException catch (_) {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// ملفات تطبيق: المسارات دائماً، والمحتوى إن توفر Shizuku.
  static Future<Map<String, dynamic>?> appFiles(String packageName) async {
    if (!_isAndroid) return null;
    try {
      final m = await _channel.invokeMapMethod<String, dynamic>(
        'appFiles',
        {'packageName': packageName},
      );
      return m?.cast<String, dynamic>();
    } on PlatformException catch (_) {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// قائمة موجزة تُحقن في موجه الذكاء الاصطناعي ليتعرف على تطبيقات الجهاز.
  ///
  /// تُقتصر على تطبيقات المستخدم القابلة للإطلاق، وبحد أقصى [limit] سطراً
  /// حتى لا ينفجر حجم السياق (التطبيقات النظامية تُستثنى لأنها نادرة الطلب).
  static Future<String> promptInventory({int limit = 120}) async {
    final apps = await listApps(includeSystem: false);
    final launchable = apps.where((a) => a.hasLauncher && a.enabled).toList()
      ..sort((a, b) => a.appName.toLowerCase().compareTo(b.appName.toLowerCase()));
    final take = launchable.take(limit).toList(growable: false);
    if (take.isEmpty) return '';
    final more = launchable.length - take.length;
    final lines = take.map((a) => a.promptLine).join('، ');
    return more > 0 ? '$lines (+$more أخرى)' : lines;
  }

  // ── أدوات نصية ──

  /// تطبيع عربي (نفس منطق IntentParserService — مكرر عمداً لأن هذه
  /// الطبقة تُستدعى أحياناً قبل تحميل المحلل).
  static String normalizeArabic(String input) {
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
    t = t.replaceAll(RegExp(r'\s+'), ' ');
    return t.trim();
  }

  /// تحويل بايت إلى نص عربي مقروء.
  static String humanSize(num bytes) {
    if (bytes <= 0) return '0 بايت';
    const units = ['بايت', 'كيلوبايت', 'ميجابايت', 'جيجابايت', 'تيرابايت'];
    var value = bytes.toDouble();
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    final s = value >= 100 ? value.toStringAsFixed(0) : value.toStringAsFixed(1);
    return '$s ${units[unit]}';
  }
}
