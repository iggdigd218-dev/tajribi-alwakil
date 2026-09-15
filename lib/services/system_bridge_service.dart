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

  static void _ensureAndroid() {
    if (!_isAndroid) {
      throw UnsupportedError('SystemBridgeService متاح على أندرويد فقط');
    }
  }
}
