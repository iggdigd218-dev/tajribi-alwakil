import 'package:flutter/services.dart';

/// جسر Dart لمدير الجدولة الدقيقة (المرحلة 3).
///
/// يرتبط بالقناة الأصلية "com.example.app/scheduler" (المسجلة في
/// MainActivity.kt) لتوفير: جدولة المهام الدقيقة، إلغاؤها، والتحكم
/// بالخدمة الأمامية الدائمة.
class SchedulerService {
  SchedulerService._();

  static const MethodChannel _channel =
      MethodChannel('com.example.app/scheduler');

  /// جدولة مهمة تُنفَّذ في وقت محدد بدقة تختبر Doze Mode.
  ///
  /// [taskId] معرّف فريد — يُستخدم للإلغاء لاحقاً.
  /// [executionTime] وقت التنفيذ.
  /// [actionType] نوع الأمر (مطابق لثوابت SystemBridgeManager مثل
  /// toggle_wifi / open_app / call / shell_command / ui_click ...).
  /// [data] معاملات التنفيذ (تصل للمستقبل كـ payloadJson).
  static Future<bool> scheduleTask(
    String taskId,
    DateTime executionTime,
    String actionType,
    Map<String, dynamic> data,
  ) async {
    try {
      return await _channel.invokeMethod<bool>('scheduleTask', {
            'taskId': taskId,
            'triggerAtMillis': executionTime.millisecondsSinceEpoch,
            'actionType': actionType,
            'payload': data,
          }) ??
          false;
    } on PlatformException {
      return false;
    }
  }

  /// إلغاء مهمة مجدولة عبر معرّفها.
  static Future<bool> cancelTask(String taskId) async {
    try {
      return await _channel.invokeMethod<bool>('cancelTask', {
            'taskId': taskId,
          }) ??
          false;
    } on PlatformException {
      return false;
    }
  }

  /// تشغيل الخدمة الأمامية الدائمة
  /// ("وكيل الأتمتة يعمل في الخلفية").
  static Future<bool> startForegroundService() async {
    try {
      return await _channel.invokeMethod<bool>('startForegroundService') ??
          false;
    } on PlatformException {
      return false;
    }
  }

  /// إيقاف الخدمة الأمامية الدائمة.
  static Future<bool> stopForegroundService() async {
    try {
      return await _channel.invokeMethod<bool>('stopForegroundService') ??
          false;
    } on PlatformException {
      return false;
    }
  }

  /// هل الخدمة الأمامية تعمل الآن؟
  static Future<bool> isForegroundServiceRunning() async {
    try {
      return await _channel.invokeMethod<bool>('isForegroundServiceRunning') ??
          false;
    } on PlatformException {
      return false;
    }
  }

  /// هل صلاحية التنبيهات الدقيقة ممنوحة؟ (أندرويد 12+)
  static Future<bool> isExactAlarmAllowed() async {
    try {
      return await _channel.invokeMethod<bool>('isExactAlarmAllowed') ?? true;
    } on PlatformException {
      return true;
    }
  }

  /// فتح شاشة طلب صلاحية "التنبيهات والتذكيرات الدقيقة" في الإعدادات.
  static Future<bool> requestExactAlarmPermission() async {
    try {
      return await _channel.invokeMethod<bool>('requestExactAlarmPermission') ??
          false;
    } on PlatformException {
      return false;
    }
  }
}
