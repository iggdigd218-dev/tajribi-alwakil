/// فئات الأوامر المدعومة في نظام الوكيل (المرحلة 4).
enum ActionCategory { system, automation, scheduler, payment, call }

/// أنواع الأوامر الموحدة بين Dart و Kotlin
/// (تطابق ثوابت SystemBridgeManager على الطبقة الأصلية).
class AgentActionTypes {
  AgentActionTypes._();

  static const String toggleWifi = 'toggle_wifi';
  static const String toggleMobileData = 'toggle_mobile_data';
  static const String openApp = 'open_app';
  static const String call = 'call';
  static const String shellCommand = 'shell_command';
  static const String inputTap = 'input_tap';
  static const String inputText = 'input_text';
  static const String uiClick = 'ui_click';
  static const String uiSetText = 'ui_set_text';
  static const String payment = 'payment';
}

/// نيّة (Intent) أمر واحد قابلة للتنفيذ — النموذج المركزي
/// الذي يُنتجه المحلل ويستهلكه المفرّق.
class AgentActionIntent {
  AgentActionIntent({
    required this.id,
    required this.rawText,
    required this.actionType,
    required this.category,
    this.targetApp,
    Map<String, dynamic>? parameters,
    this.scheduledTime,
    this.requiresConfirmation = false,
  }) : parameters = parameters ?? <String, dynamic>{};

  /// معرّف فريد للنية.
  final String id;

  /// نص الأمر الأصلي كما كتبه المستخدم.
  final String rawText;

  /// نوع الأمر (من [AgentActionTypes]).
  final String actionType;

  /// فئة الأمر (من [ActionCategory]).
  final ActionCategory category;

  /// التطبيق/المحفظة المستهدفة (اسم وصفي مثل "واتساب").
  final String? targetApp;

  /// معاملات التنفيذ مثل enable / phoneNumber / packageName / amount.
  final Map<String, dynamic> parameters;

  /// وقت التنفيذ المجدول — null إذا كان الأمر فورياً.
  final DateTime? scheduledTime;

  /// هل تتطلب العملية تأكيداً أمنياً صريحاً قبل التنفيذ؟
  /// (تُضبط تلقائياً للعمليات المالية).
  final bool requiresConfirmation;

  /// هل المهمة مجدولة في المستقبل؟
  bool get isScheduled =>
      scheduledTime != null && scheduledTime!.isAfter(DateTime.now());

  factory AgentActionIntent.fromJson(Map<String, dynamic> json) {
    return AgentActionIntent(
      id: json['id'] as String? ??
          'intent_${DateTime.now().microsecondsSinceEpoch}',
      rawText: json['rawText'] as String? ?? '',
      actionType: json['actionType'] as String? ?? AgentActionTypes.shellCommand,
      category: _categoryFromName(json['category'] as String?),
      targetApp: json['targetApp'] as String?,
      parameters:
          (json['parameters'] as Map<Object?, Object?>?)?.cast<String, dynamic>() ??
              <String, dynamic>{},
      scheduledTime: json['scheduledTime'] != null
          ? DateTime.tryParse(json['scheduledTime'].toString())
          : null,
      requiresConfirmation: json['requiresConfirmation'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'rawText': rawText,
        'actionType': actionType,
        'category': category.name,
        'targetApp': targetApp,
        'parameters': parameters,
        'scheduledTime': scheduledTime?.toIso8601String(),
        'requiresConfirmation': requiresConfirmation,
      };

  static ActionCategory _categoryFromName(String? name) {
    switch (name) {
      case 'system':
        return ActionCategory.system;
      case 'automation':
        return ActionCategory.automation;
      case 'scheduler':
        return ActionCategory.scheduler;
      case 'payment':
        return ActionCategory.payment;
      case 'call':
        return ActionCategory.call;
      default:
        return ActionCategory.system;
    }
  }

  @override
  String toString() =>
      'AgentActionIntent($actionType, category: ${category.name}, '
      'target: $targetApp, params: $parameters, '
      'at: $scheduledTime, confirm: $requiresConfirmation)';
}
