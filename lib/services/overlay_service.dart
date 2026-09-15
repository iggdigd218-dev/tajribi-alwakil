import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/services.dart';

/// جسر Dart للنافذة العائمة ومساعد النظام الافتراضي.
///
/// القناة: "com.example.app/overlay"
class OverlayService {
  OverlayService._();

  static const MethodChannel _channel =
      MethodChannel('com.example.app/overlay');

  static bool get _isAndroid =>
      defaultTargetPlatform == TargetPlatform.android;

  static Future<bool> hasOverlayPermission() async {
    if (!_isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('hasOverlayPermission') ??
          false;
    } on PlatformException {
      return false;
    }
  }

  /// يفتح صفحة صلاحية «العرض فوق التطبيقات».
  static Future<bool> requestOverlayPermission() async {
    if (!_isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('requestOverlayPermission') ??
          false;
    } on PlatformException {
      return false;
    }
  }

  static Future<bool> showOverlay() async {
    if (!_isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('showOverlay') ?? false;
    } on PlatformException {
      return false;
    }
  }

  static Future<bool> hideOverlay() async {
    if (!_isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('hideOverlay') ?? false;
    } on PlatformException {
      return false;
    }
  }

  static Future<bool> isOverlayShowing() async {
    if (!_isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('isOverlayShowing') ?? false;
    } on PlatformException {
      return false;
    }
  }

  /// هل هذا التطبيق هو المساعد الرقمي الافتراضي؟
  static Future<bool> isDefaultAssistant() async {
    if (!_isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('isDefaultAssistant') ?? false;
    } on PlatformException {
      return false;
    }
  }

  /// يفتح إعدادات اختيار تطبيق المساعد الافتراضي.
  static Future<bool> openAssistantSettings() async {
    if (!_isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('openAssistantSettings') ??
          false;
    } on PlatformException {
      return false;
    }
  }
}
