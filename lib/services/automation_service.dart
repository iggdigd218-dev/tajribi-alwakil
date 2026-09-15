import 'package:flutter/services.dart';

import '../automation/accessibility_bridge.dart';

/// الواجهة الموحدة لمحرك الأتمتة (المرحلة 1) — تغليف AccessibilityBridge
/// (قناة com.example.app/accessibility_automation) بأوامر جاهزة
/// يستهلكها المفرّق المركزي في المرحلة 4.
class AutomationService {
  AutomationService._();

  /// هل خدمة الإمكانية مفعّلة ومتصلة؟
  static Future<bool> isServiceRunning() =>
      AccessibilityBridge.isServiceRunning();

  /// فتح إعدادات إمكانية الوصول لتفعيل الخدمة يدوياً.
  static Future<bool> openAccessibilitySettings() =>
      AccessibilityBridge.openAccessibilitySettings();

  /// البحث بالنص ثم النقر على أول عنصر مطابق.
  static Future<bool> findAndClick(String text) async {
    final node = await AccessibilityBridge.findNodeByText(text);
    if (node == null) return false;
    try {
      return await AccessibilityBridge.clickNode(node);
    } on PlatformException {
      return false;
    }
  }

  /// البحث بمعرّف العرض ثم النقر عليه.
  static Future<bool> findIdAndClick(String viewId) async {
    final node = await AccessibilityBridge.findNodeById(viewId);
    if (node == null) return false;
    try {
      return await AccessibilityBridge.clickNode(node);
    } on PlatformException {
      return false;
    }
  }

  /// تعبئة حقل نصي: ابحث بالمعرّف أو بالنص ثم اكتب القيمة.
  static Future<bool> setNodeText({
    String? viewId,
    String? byText,
    required String value,
  }) async {
    final node = viewId != null
        ? await AccessibilityBridge.findNodeById(viewId)
        : await AccessibilityBridge.findNodeByText(byText ?? '');
    if (node == null) return false;
    try {
      return await AccessibilityBridge.setText(node, value);
    } on PlatformException {
      return false;
    }
  }

  /// نقرة بإحداثيات الشاشة عبر dispatchGesture.
  static Future<bool> tapCoordinates(double x, double y) =>
      AccessibilityBridge.clickAtCoordinates(x, y);
}
