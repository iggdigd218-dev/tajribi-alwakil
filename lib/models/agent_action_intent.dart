/// فئات الأوامر المدعومة في نظام الوكيل.
enum ActionCategory {
  system,
  automation,
  scheduler,
  payment,
  call,
  apps,
  files,
  device,
  media,
  messaging,
  info,
}

/// أنواع الأوامر الموحدة بين Dart و Kotlin.
///
/// الأوامر العشرة الأولى تطابق ثوابت SystemBridgeManager على الطبقة الأصلية.
/// الباقي أوامر «مستوى أعلى» يفككها AgentDispatcher إلى أوامر أصلية
/// أو إلى Shell عبر Shizuku — فلا تحتاج تعديل الطبقة الأصلية كلها.
class AgentActionTypes {
  AgentActionTypes._();

  // ── المرحلة 2: أوامر النظام الأصلية ──
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

  // ── المرحلة 6: إعدادات النظام الإضافية ──
  static const String toggleBluetooth = 'toggle_bluetooth';
  static const String toggleAirplane = 'toggle_airplane';
  static const String toggleFlashlight = 'toggle_flashlight';
  static const String setBrightness = 'set_brightness';
  static const String toggleRotation = 'toggle_rotation';
  static const String setVolume = 'set_volume';
  static const String setDnd = 'set_dnd';
  static const String rebootDevice = 'reboot_device';
  static const String lockScreen = 'lock_screen';
  static const String openSettingsPage = 'open_settings_page';
  static const String navigateUi = 'navigate_ui'; // back | home | recents
  static const String screenshot = 'screenshot';

  // ── المرحلة 6: التطبيقات المثبتة ──
  static const String listApps = 'list_apps';
  static const String appInfo = 'app_info';
  static const String uninstallApp = 'uninstall_app';
  static const String forceStopApp = 'force_stop_app';
  static const String clearAppCache = 'clear_app_cache';
  static const String appFiles = 'app_files';

  // ── المرحلة 6: الملفات ──
  static const String listFiles = 'list_files';
  static const String findFile = 'find_file';
  static const String storageInfo = 'storage_info';

  // ── المرحلة 6: معلومات الجهاز ──
  static const String deviceInfo = 'device_info';
  static const String batteryInfo = 'battery_info';

  // ── المرحلة 6: الوسائط والاتصال ──
  static const String mediaControl = 'media_control'; // play|pause|next|prev
  static const String sendMessage = 'send_message';
  static const String openUrl = 'open_url';
  static const String searchWeb = 'search_web';
  static const String openCamera = 'open_camera';
  static const String openContacts = 'open_contacts';
  static const String sendEmail = 'send_email';

  /// كل الأنواع المعروفة — يُستخدم للتحقق من مخرجات الذكاء الاصطناعي.
  static const Set<String> all = <String>{
    toggleWifi, toggleMobileData, openApp, call, shellCommand,
    inputTap, inputText, uiClick, uiSetText, payment,
    toggleBluetooth, toggleAirplane, toggleFlashlight, setBrightness,
    toggleRotation, setVolume, setDnd, rebootDevice, lockScreen,
    openSettingsPage, navigateUi, screenshot,
    listApps, appInfo, uninstallApp, forceStopApp, clearAppCache, appFiles,
    listFiles, findFile, storageInfo,
    deviceInfo, batteryInfo,
    mediaControl, sendMessage, openUrl, searchWeb, openCamera,
    openContacts, sendEmail,
  };

  static bool isKnown(String type) => all.contains(type);
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
  /// (تُضبط تلقائياً للعمليات المالية والهدّامة مثل إلغاء التثبيت).
  final bool requiresConfirmation;

  /// هل المهمة مجدولة في المستقبل؟
  bool get isScheduled =>
      scheduledTime != null && scheduledTime!.isAfter(DateTime.now());

  /// معرّف الحزمة إن حُلّ — يقراه المفرّق لفتح/إدارة التطبيق.
  String? get packageName => parameters['packageName'] as String?;

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

  /// نسخة من النيّة بعد استبدال/إضافة معاملات — تُستخدم عندما يحلّ
  /// المفرّق اسم التطبيق إلى معرّف حزمة فعلي من جهاز المستخدم.
  AgentActionIntent withParameters(Map<String, dynamic> patch) {
    return AgentActionIntent(
      id: id,
      rawText: rawText,
      actionType: actionType,
      category: category,
      targetApp: targetApp,
      parameters: <String, dynamic>{...parameters, ...patch},
      scheduledTime: scheduledTime,
      requiresConfirmation: requiresConfirmation,
    );
  }

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
      case 'apps':
        return ActionCategory.apps;
      case 'files':
        return ActionCategory.files;
      case 'device':
        return ActionCategory.device;
      case 'media':
        return ActionCategory.media;
      case 'messaging':
        return ActionCategory.messaging;
      case 'info':
        return ActionCategory.info;
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
