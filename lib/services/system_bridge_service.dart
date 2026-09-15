import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/services.dart';

/// حالة Shizuku على الجهاز.
class ShizukuStatus {
  const ShizukuStatus({
    required this.shizukuRunning,
    required this.permissionGranted,
  });

  /// هل تطبيق Shizuku يعمل (الخدمة حية)؟
  final bool shizukuRunning;

  /// هل مُنح تطبيقنا صلاحية الاستخدام؟
  final bool permissionGranted;

  /// جاهزية كاملة للتنفيذ.
  bool get isReady => shizukuRunning && permissionGranted;
}

/// جسر Dart للتحكم العميق في النظام عبر Shizuku (المرحلة 2).
///
/// يرتبط بالقناة الأصلية "com.example.app/system_bridge"
/// (المسجلة في SystemBridgeManager.kt).
class SystemBridgeService {
  SystemBridgeService._();

  static const MethodChannel _channel =
      MethodChannel('com.example.app/system_bridge');

  static bool get _isAndroid =>
      defaultTargetPlatform == TargetPlatform.android;

  // ─────────────────────────────────────────────
  //  حالة Shizuku والصلاحيات
  // ─────────────────────────────────────────────

  /// فحص حالة Shizuku: هل الخدمة تعمل وهل الصلاحية ممنوحة؟
  static Future<ShizukuStatus> checkShizukuPermission() async {
    if (!_isAndroid) {
      return const ShizukuStatus(
        shizukuRunning: false,
        permissionGranted: false,
      );
    }
    try {
      final map =
          await _channel.invokeMapMethod<String, dynamic>('checkShizukuPermission');
      return ShizukuStatus(
        shizukuRunning: map?['shizukuRunning'] as bool? ?? false,
        permissionGranted: map?['permissionGranted'] as bool? ?? false,
      );
    } on PlatformException {
      return const ShizukuStatus(
        shizukuRunning: false,
        permissionGranted: false,
      );
    }
  }

  /// طلب صلاحية Shizuku — يفتح مربع حوار في تطبيق Shizuku
  /// ويعيد true عند الموافقة.
  static Future<bool> requestShizukuPermission() async {
    if (!_isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('requestShizukuPermission') ??
          false;
    } on PlatformException {
      return false;
    }
  }

  // ─────────────────────────────────────────────
  //  أوامر النظام
  // ─────────────────────────────────────────────

  /// تنفيذ أمر Shell مباشرة بصلاحيات Shizuku.
  static Future<String> runShellCommand(String command) async {
    _ensureAndroid();
    return await _channel
            .invokeMethod<String>('runShellCommand', {'command': command}) ??
        '';
  }

  /// أمر نظام موحد — يستخدمه المفرّق المركزي:
  /// [setting] = mobileData | wifi | call
  static Future<String> setSystemSetting({
    required String setting,
    bool? enable,
    String? phoneNumber,
    int slotIndex = 0,
  }) async {
    _ensureAndroid();
    return await _channel.invokeMethod<String>('setSystemSetting', {
          'setting': setting,
          if (enable != null) 'enable': enable,
          if (phoneNumber != null) 'phoneNumber': phoneNumber,
          'slotIndex': slotIndex,
        }) ??
        '';
  }

  /// تفعيل/تعطيل بيانات الهاتف (svc data enable/disable).
  static Future<String> toggleMobileData(bool enable) =>
      setSystemSetting(setting: 'mobileData', enable: enable);

  /// تفعيل/تعطيل الواي فاي (svc wifi enable/disable).
  static Future<String> toggleWifi(bool enable) =>
      setSystemSetting(setting: 'wifi', enable: enable);

  /// يبحث في جهات الاتصال عن اسم ويعيد أول رقم مطابق — فارغ إن لم يوجد.
  static Future<String> findContactNumber(String name) async {
    try {
      return await _channel
              .invokeMethod<String>('findContactNumber', {'name': name}) ??
          '';
    } on PlatformException {
      return '';
    }
  }

  /// تشغيل اتصال مباشر — [slotIndex]: 0 = الشريحة 1، 1 = الشريحة 2.
  static Future<String> dialCall(String phoneNumber, {int slotIndex = 0}) =>
      setSystemSetting(
        setting: 'call',
        phoneNumber: phoneNumber,
        slotIndex: slotIndex,
      );

  /// فتح تطبيق — يمرر extras اختيارية عبر am start --es.
  static Future<String> launchApp(
    String packageName, {
    String? activity,
    Map<String, String>? extras,
  }) async {
    _ensureAndroid();
    return await _channel.invokeMethod<String>('launchApp', {
          'packageName': packageName,
          if (activity != null) 'activity': activity,
          if (extras != null) 'extras': extras,
        }) ??
        '';
  }

  /// نقرة بإحداثيات الشاشة (input tap).
  static Future<String> inputTap(int x, int y) async {
    _ensureAndroid();
    return await _channel
            .invokeMethod<String>('inputTap', {'x': x, 'y': y}) ??
        '';
  }

  /// كتابة مباشرة في الحقل المركز (input text).
  static Future<String> inputText(String text) async {
    _ensureAndroid();
    return await _channel
            .invokeMethod<String>('inputText', {'text': text}) ??
        '';
  }

  // ─────────────────────────────────────────────
  //  المرحلة 6: أوامر تعمل دون Shizuku
  // ─────────────────────────────────────────────

  /// الكشاف عبر CameraManager — لا يحتاج أي صلاحية خاصة.
  static Future<String> setFlashlight(bool enable) =>
      _invoke('setFlashlight', {'enable': enable});

  /// ضبط صوت الوسائط — [percent] بين 0 و100، أو [mute] للكتم.
  static Future<String> setVolume({int? percent, bool mute = false}) =>
      _invoke('setVolume', {
        if (percent != null) 'percent': percent,
        'mute': mute,
      });

  /// فتح نيّة نظام قياسية (صفحة إعدادات / كاميرا / متصفح / …).
  static Future<String> openSystemIntent(String key, {String? extra}) =>
      _invoke('openSystemIntent', {
        'key': key,
        if (extra != null) 'extra': extra,
      });

  /// فتح مسودة رسالة نصية مع الرقم والنص جاهزين.
  ///
  /// الإرسال الفعلي يحتاج صلاحية SEND_SMS غير المضمّنة عمداً —
  /// نملأ المسودة ويضغط المستخدم «إرسال» بيده.
  static Future<String> openSmsCompose(String phoneNumber, String body) =>
      _invoke('openSmsCompose', {'phoneNumber': phoneNumber, 'body': body});

  /// فتح محادثة واتساب مباشرة مع رقم (عبر wa.me).
  static Future<String> openWhatsAppChat(String phoneNumber, String body) =>
      _invoke('openWhatsAppChat', {'phoneNumber': phoneNumber, 'body': body});

  // ─────────────────────────────────────────────
  //  المرحلة 6: أوامر تحتاج Shizuku ولها مسار بديل
  // ─────────────────────────────────────────────

  static Future<String> toggleBluetooth(bool enable) =>
      _invoke('toggleBluetooth', {'enable': enable});

  static Future<String> toggleAirplane(bool enable) =>
      _invoke('toggleAirplane', {'enable': enable});

  /// [percent] بين 0 و100، أو [auto] للسطوع التلقائي.
  static Future<String> setBrightness({int? percent, bool? auto}) =>
      _invoke('setBrightness', {
        if (percent != null) 'percent': percent,
        if (auto != null) 'auto': auto,
      });

  /// [orientation] هي landscape أو portrait، و[auto] للدوران التلقائي.
  static Future<String> toggleRotation({String? orientation, bool? auto}) =>
      _invoke('toggleRotation', {
        if (orientation != null) 'orientation': orientation,
        if (auto != null) 'auto': auto,
      });

  static Future<String> setDnd(bool enable) =>
      _invoke('setDnd', {'enable': enable});

  /// [target] هي back أو home أو recents.
  static Future<String> navigateUi(String target) =>
      _invoke('navigateUi', {'target': target});

  static Future<String> screenshot() =>
      _invoke('screenshot', const <String, dynamic>{});

  static Future<String> lockScreen() =>
      _invoke('lockScreen', const <String, dynamic>{});

  static Future<String> rebootDevice() =>
      _invoke('rebootDevice', const <String, dynamic>{});

  /// [op] هي play أو pause أو next أو prev أو stop.
  static Future<String> mediaControl(String op) =>
      _invoke('mediaControl', {'op': op});

  static Future<String> forceStopApp(String packageName) =>
      _invoke('forceStopApp', {'packageName': packageName});

  static Future<String> clearAppCache(String packageName) =>
      _invoke('clearAppCache', {'packageName': packageName});

  // ─────────────────────────────────────────────

  /// لفّ موحد: يستدعي القناة ويتحمّل غيابها (منصة أخرى / جسر قديم)
  /// بدل رمي استثناء يكسر تدفق المحادثة.
  static Future<String> _invoke(
    String method,
    Map<String, dynamic> args,
  ) async {
    if (!_isAndroid) {
      throw UnsupportedError('SystemBridgeService متاح على أندرويد فقط');
    }
    try {
      return await _channel.invokeMethod<String>(method, args) ?? '';
    } on MissingPluginException {
      return 'الجسر الأصلي لا يدعم «$method» — يلزم بناء نسخة أحدث من التطبيق';
    } on PlatformException catch (e) {
      return 'خطأ [${e.code}]: ${e.message ?? 'غير معروف'}';
    }
  }

  static void _ensureAndroid() {
    if (!_isAndroid) {
      throw UnsupportedError('SystemBridgeService متاح على أندرويد فقط');
    }
  }
}
