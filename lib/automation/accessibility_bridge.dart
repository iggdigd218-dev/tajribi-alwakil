import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/services.dart';

/// الجسر الموحّد للتواصل مع محرك الأتمتة (AccessibilityService) على أندرويد
/// عبر MethodChannel باسم: `com.example.app/accessibility_automation`.
///
/// نمط الاستخدام النموذجي:
/// ```dart
/// if (!await AccessibilityBridge.isServiceRunning()) {
///   await AccessibilityBridge.openAccessibilitySettings();
///   return;
/// }
/// final btn = await AccessibilityBridge.findNodeByText('تسجيل الدخول');
/// if (btn != null) await AccessibilityBridge.clickNode(btn);
/// ```
class AccessibilityBridge {
  AccessibilityBridge._();

  static const MethodChannel _channel =
      MethodChannel('com.example.app/accessibility_automation');

  static bool get _isAndroid =>
      defaultTargetPlatform == TargetPlatform.android;

  /// هل خدمة الأتمتة مفعّلة من إعدادات النظام ومتصلة الآن؟
  static Future<bool> isServiceRunning() async {
    if (!_isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('isServiceRunning') ?? false;
    } on PlatformException {
      return false;
    }
  }

  /// فتح شاشة "إعدادات إمكانية الوصول" في النظام لتفعيل الخدمة يدوياً.
  static Future<bool> openAccessibilitySettings() async {
    if (!_isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('openAccessibilitySettings') ??
          false;
    } on PlatformException {
      return false;
    }
  }

  /// معلومات آخر نافذة نشطة رصدتها الخدمة (اسم الحزمة والفئة).
  static Future<Map<String, String?>> getActiveWindow() async {
    _ensureAndroid();
    return await _channel.invokeMapMethod<String, String?>('getActiveWindow') ??
        <String, String?>{};
  }

  /// البحث عن أول عنصر نصّه أو وصفه يحتوي على [text]
  /// (بحث جزئي غير حساس لحالة الأحرف).
  ///
  /// يعيد [AgentNode] عند العثور عليه، أو `null` إن لم يوجد.
  static Future<AgentNode?> findNodeByText(String text) async {
    _ensureAndroid();
    final map = await _channel
        .invokeMapMethod<String, dynamic>('findNodeByText', {'text': text});
    return map == null ? null : AgentNode._fromMap(map);
  }

  /// البحث عن أول عنصر عبر معرّف العرض بالصيغة الكاملة:
  /// `"com.example.target:id/button_submit"`
  static Future<AgentNode?> findNodeById(String viewId) async {
    _ensureAndroid();
    final map = await _channel
        .invokeMapMethod<String, dynamic>('findNodeById', {'viewId': viewId});
    return map == null ? null : AgentNode._fromMap(map);
  }

  /// محاكاة النقر على عنصر تم العثور عليه مسبقاً.
  ///
  /// يرمي [PlatformException] بكود `NODE_NOT_FOUND` إذا انتهت صلاحية
  /// العنصر (تغيّرت الشاشة)، وبكود `SERVICE_NOT_ENABLED` إذا أُوقفت الخدمة.
  static Future<bool> clickNode(AgentNode node) async {
    _ensureAndroid();
    return await _channel
            .invokeMethod<bool>('clickNode', {'handle': node.handle}) ??
        false;
  }

  /// تعبئة حقل نصي (يستبدل المحتوى الحالي بالكامل).
  static Future<bool> setText(AgentNode node, String text) async {
    _ensureAndroid();
    return await _channel.invokeMethod<bool>(
          'setText',
          {'handle': node.handle, 'text': text},
        ) ??
        false;
  }

  /// تنفيذ نقرة بإحداثيات شاشة مطلقة (بالبكسل).
  static Future<bool> clickAtCoordinates(double x, double y) async {
    _ensureAndroid();
    return await _channel.invokeMethod<bool>(
          'clickAtCoordinates',
          {'x': x, 'y': y},
        ) ??
        false;
  }

  static void _ensureAndroid() {
    if (!_isAndroid) {
      throw UnsupportedError('AccessibilityBridge متاح على أندرويد فقط');
    }
  }
}

/// تمثيل عنصر واجهة تم اكتشافه عبر الخدمة، مع مقبض أصلي (handle)
/// للرجوع إليه في العمليات اللاحقة (نقر / تعبئة نص).
class AgentNode {
  const AgentNode._({
    required this.handle,
    required this.text,
    required this.viewId,
    required this.className,
    required this.packageName,
    required this.contentDescription,
    required this.clickable,
    required this.editable,
    required this.scrollable,
    required this.bounds,
  });

  /// المقبض الرقمي المرتبط بالعنصر في الطبقة الأصلية (Kotlin).
  final int handle;
  final String? text;
  final String? viewId;
  final String? className;
  final String? packageName;
  final String? contentDescription;
  final bool clickable;
  final bool editable;
  final bool scrollable;

  /// إحداثيات العنصر على الشاشة (بالبكسل).
  final NodeBounds bounds;

  factory AgentNode._fromMap(Map<Object?, Object?> map) => AgentNode._(
        handle: map['handle'] as int,
        text: map['text'] as String?,
        viewId: map['viewId'] as String?,
        className: map['className'] as String?,
        packageName: map['packageName'] as String?,
        contentDescription: map['contentDescription'] as String?,
        clickable: map['clickable'] as bool? ?? false,
        editable: map['editable'] as bool? ?? false,
        scrollable: map['scrollable'] as bool? ?? false,
        bounds: NodeBounds._fromMap(map['bounds'] as Map<Object?, Object?>?),
      );

  @override
  String toString() =>
      'AgentNode(handle: $handle, text: $text, viewId: $viewId, '
      'clickable: $clickable)';
}

/// مستطيل إحداثيات العنصر على الشاشة (بالبكسل).
class NodeBounds {
  const NodeBounds({
    this.left = 0,
    this.top = 0,
    this.right = 0,
    this.bottom = 0,
  });

  final int left;
  final int top;
  final int right;
  final int bottom;

  factory NodeBounds._fromMap(Map<Object?, Object?>? map) => NodeBounds(
        left: map?['left'] as int? ?? 0,
        top: map?['top'] as int? ?? 0,
        right: map?['right'] as int? ?? 0,
        bottom: map?['bottom'] as int? ?? 0,
      );

  int get width => right - left;
  int get height => bottom - top;

  @override
  String toString() => 'NodeBounds(l: $left, t: $top, r: $right, b: $bottom)';
}
