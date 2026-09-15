import 'package:flutter/services.dart';

import '../models/agent_action_intent.dart';
import 'automation_service.dart';
import 'device_knowledge_service.dart';
import 'scheduler_service.dart';
import 'system_bridge_service.dart';

/// حالات نتيجة التنفيذ.
enum AgentDispatchStatus {
  executed,
  scheduled,
  needsConfirmation,
  failed,
  degraded, // نُفّذ جزئياً / فُتحت شاشة النظام بدل التنفيذ المباشر
  unknownCommand,
}

/// نتيجة توجيه وتنفيذ نيّة واحدة.
class AgentDispatchResult {
  const AgentDispatchResult({
    required this.status,
    required this.message,
    required this.intent,
  });

  final AgentDispatchStatus status;
  final String message;
  final AgentActionIntent intent;

  /// هل نجح التنفيذ بشكل ما (كامل أو بديل)؟
  bool get isUsable =>
      status == AgentDispatchStatus.executed ||
      status == AgentDispatchStatus.scheduled ||
      status == AgentDispatchStatus.degraded;
}

/// المفرّق والمنفّذ المركزي (المرحلة 4 + المرحلة 6).
///
/// يستقبل [AgentActionIntent] ويوجّهه إلى المسار الصحيح:
///
///  - نيّة مجدولة → SchedulerService.
///  - أمر نظام → SystemBridgeService (Shizuku عند توفره).
///  - **أمر نظام بلا Shizuku → مسار بديل**: يفتح شاشة النظام المناسبة
///    أو يستخدم واجهة أندرويد العامة (CameraManager/AudioManager/Intent)
///    بدل الفشل. هذا ما يجعل التطبيق مفيداً على أي جهاز.
///  - أمر تطبيق → يحلّ معرّف الحزمة من الجهاز إن لم يكن معروفاً.
///  - أمر معلوماتي → يقرأ البيانات المحلية ويردّ بها (بلا تنفيذ).
///  - عملية مالية أو هدّامة → تتطلب تأكيداً صريحاً.
class AgentDispatcher {
  AgentDispatcher._();

  /// تنفيذ نيّة واحدة.
  ///
  /// [confirmed] يجب أن تكون true للعمليات التي تتطلب تأكيداً —
  /// الواجهة تعرض بطاقة تأكيد وتستدعي التنفيذ مجدداً بعد الموافقة.
  static Future<AgentDispatchResult> execute(
    AgentActionIntent intent, {
    bool confirmed = false,
  }) async {
    try {
      // ── 1) البوابة الأمنية: العمليات المالية والهدّامة
      if (intent.requiresConfirmation && !confirmed) {
        return AgentDispatchResult(
          status: AgentDispatchStatus.needsConfirmation,
          message: _confirmationSummary(intent),
          intent: intent,
        );
      }

      // ── 2) مهمة مجدولة بمستقبل → SchedulerService
      if (intent.isScheduled) {
        // الجدولة الخلفية تحتاج معرّف حزمة محلولاً مسبقاً
        final resolved = await _ensurePackage(intent);
        final ok = await SchedulerService.scheduleTask(
          resolved.id,
          resolved.scheduledTime!,
          resolved.actionType,
          resolved.parameters,
        );
        return AgentDispatchResult(
          status:
              ok ? AgentDispatchStatus.scheduled : AgentDispatchStatus.failed,
          message: ok
              ? 'سيتم تنفيذ "${resolved.rawText}" في الموعد المحدد'
              : 'فشلت جدولة المهمة — تحقق من صلاحية التنبيهات الدقيقة',
          intent: resolved,
        );
      }

      // ── 3) الأوامر المعلوماتية — تُجاب من بيانات الجهاز المحلية
      final info = await _tryInfoAction(intent);
      if (info != null) return info;

      // ── 4) التنفيذ حسب نوع الأمر
      switch (intent.actionType) {
        // ═══ الشبكة ═══
        case AgentActionTypes.toggleWifi:
          final enable = intent.parameters['enable'] == true;
          final out = await SystemBridgeService.toggleWifi(enable);
          return _wrapShell(
            intent,
            out,
            'تم ${enable ? "تفعيل" : "تعطيل"} الواي فاي',
            fallbackKey: 'settings.wifi',
          );

        case AgentActionTypes.toggleMobileData:
          final enable = intent.parameters['enable'] == true;
          final out = await SystemBridgeService.toggleMobileData(enable);
          return _wrapShell(
            intent,
            out,
            'تم ${enable ? "تفعيل" : "تعطيل"} بيانات الجوال',
            fallbackKey: 'settings.data',
          );

        case AgentActionTypes.toggleBluetooth:
          final enable = intent.parameters['enable'] == true;
          final out = await SystemBridgeService.toggleBluetooth(enable);
          return _wrapShell(
            intent,
            out,
            'تم ${enable ? "تفعيل" : "تعطيل"} البلوتوث',
          );

        case AgentActionTypes.toggleAirplane:
          final enable = intent.parameters['enable'] == true;
          final out = await SystemBridgeService.toggleAirplane(enable);
          return _wrapShell(
            intent,
            out,
            'تم ${enable ? "تفعيل" : "إلغاء"} وضع الطيران',
          );

        // ═══ إعدادات الجهاز ═══
        case AgentActionTypes.toggleFlashlight:
          final enable = intent.parameters['enable'] == true;
          // الكشاف لا يحتاج Shizuku إطلاقاً — مسار مباشر دائماً
          final out = await SystemBridgeService.setFlashlight(enable);
          return _ok(intent, out);

        case AgentActionTypes.setBrightness:
          final out = await SystemBridgeService.setBrightness(
            percent: (intent.parameters['percent'] as num?)?.toInt(),
            auto: intent.parameters['auto'] as bool?,
          );
          if (intent.parameters['auto'] == true) {
            return _ok(intent, 'ضُبط السطوع على الوضع التلقائي');
          }
          return _ok(intent, out);

        case AgentActionTypes.setVolume:
          final out = await SystemBridgeService.setVolume(
            percent: _resolveVolumePercent(intent),
            mute: intent.parameters['mute'] == true,
          );
          return _ok(intent, out);

        case AgentActionTypes.toggleRotation:
          final out = await SystemBridgeService.toggleRotation(
            orientation: intent.parameters['orientation'] as String?,
            auto: intent.parameters['auto'] as bool?,
          );
          return _ok(intent, out);

        case AgentActionTypes.setDnd:
          final enable = intent.parameters['enable'] == true;
          final out = await SystemBridgeService.setDnd(enable);
          return _wrapShell(
            intent,
            out,
            'تم ${enable ? "تفعيل" : "إلغاء"} وضع عدم الإزعاج',
          );

        case AgentActionTypes.navigateUi:
          final target = (intent.parameters['target'] as String?) ?? 'back';
          final out = await SystemBridgeService.navigateUi(target);
          if (out.contains('يتطلب Shizuku')) {
            return AgentDispatchResult(
              status: AgentDispatchStatus.failed,
              message: 'التنقل في الواجهة (رجوع/رئيسية/الأخيرة) يتطلب Shizuku '
                  'أو خدمة إمكانية الوصول.\n'
                  'فعّل «محرك الأتمتة» من إعدادات إمكانية الوصول، '
                  'أو شغّل Shizuku.',
              intent: intent,
            );
          }
          return _ok(intent, _navigationLabel(target));

        case AgentActionTypes.screenshot:
          final out = await SystemBridgeService.screenshot();
          return _ok(intent, out);

        case AgentActionTypes.lockScreen:
          final out = await SystemBridgeService.lockScreen();
          return _ok(intent, out);

        case AgentActionTypes.rebootDevice:
          final out = await SystemBridgeService.rebootDevice();
          return _ok(intent, out);

        case AgentActionTypes.openSettingsPage:
          final page = (intent.parameters['page'] as String?) ?? 'main';
          final out = await SystemBridgeService.openSystemIntent(
            'settings.$page',
          );
          return out.startsWith('تعذّر') || out.startsWith('نيّة غير مدعومة')
              ? _fail(intent, 'تعذّر فتح صفحة ${_settingsPageLabel(page)}\n$out')
              : _ok(intent, 'فُتحت صفحة ${_settingsPageLabel(page)}');

        // ═══ التطبيقات ═══
        case AgentActionTypes.openApp:
        case AgentActionTypes.payment:
          return await _launchAppFromIntent(intent);

        case AgentActionTypes.appInfo:
          return await _appInfoFromIntent(intent);

        case AgentActionTypes.appFiles:
          return await _appFilesFromIntent(intent);

        case AgentActionTypes.uninstallApp:
          return await _uninstallAppFromIntent(intent);

        case AgentActionTypes.forceStopApp:
          return await _forceStopFromIntent(intent);

        case AgentActionTypes.clearAppCache:
          return await _clearCacheFromIntent(intent);

        case AgentActionTypes.listApps:
          return await _listAppsResult(intent);

        // ═══ الملفات ═══
        case AgentActionTypes.listFiles:
          return await _listFilesResult(intent);

        case AgentActionTypes.findFile:
          return await _findFileResult(intent);

        // ═══ الاتصال والرسائل ═══
        case AgentActionTypes.call:
          final phone = intent.parameters['phoneNumber']?.toString() ?? '';
          if (phone.isEmpty) {
            return _fail(intent, 'لم يُحدد رقم للاتصال به');
          }
          await SystemBridgeService.dialCall(
            phone,
            slotIndex: (intent.parameters['slotIndex'] as num?)?.toInt() ?? 0,
          );
          return _ok(intent, 'جارٍ بدء الاتصال بـ $phone...');

        case AgentActionTypes.sendMessage:
          final phone = intent.parameters['phoneNumber']?.toString() ?? '';
          final body = intent.parameters['text']?.toString() ?? '';
          if (phone.isEmpty) return _fail(intent, 'لم يُحدد رقم للرسالة');
          final out = intent.parameters['viaWhatsapp'] == true
              ? await SystemBridgeService.openWhatsAppChat(phone, body)
              : await SystemBridgeService.openSmsCompose(phone, body);
          return _ok(
            intent,
            '$out\n(الإرسال النهائي بيدك — لا يرسل التطبيق دون ضغطك)',
          );

        case AgentActionTypes.sendEmail:
          final to = intent.parameters['to']?.toString() ?? '';
          final out = await SystemBridgeService.openSystemIntent(
            'email',
            extra: to,
          );
          return out.startsWith('تعذّر')
              ? _fail(intent, 'تعذّر فتح تطبيق البريد\n$out')
              : _ok(intent, 'فُتح تطبيق البريد إلى $to');

        case AgentActionTypes.openContacts:
          await SystemBridgeService.openSystemIntent('contacts');
          return _ok(intent, 'فُتحت جهات الاتصال');

        case AgentActionTypes.openCamera:
          await SystemBridgeService.openSystemIntent('camera');
          return _ok(intent, 'فُتحت الكاميرا');

        // ═══ الوسائط ═══
        case AgentActionTypes.mediaControl:
          final op = (intent.parameters['op'] as String?) ?? 'play';
          final out = await SystemBridgeService.mediaControl(op);
          return _ok(intent, '${_mediaLabel(op)}\n$out');

        // ═══ الويب ═══
        case AgentActionTypes.openUrl:
          final url = intent.parameters['url']?.toString() ?? '';
          if (url.isEmpty) return _fail(intent, 'لم يُحدد رابط');
          await SystemBridgeService.openSystemIntent('browser', extra: url);
          return _ok(intent, 'فُتح الرابط في المتصفح');

        case AgentActionTypes.searchWeb:
          final q = intent.parameters['query']?.toString() ?? '';
          if (q.isEmpty) return _fail(intent, 'لم تُحدد كلمة البحث');
          await SystemBridgeService.openSystemIntent('webSearch', extra: q);
          return _ok(intent, 'فُتح البحث عن «$q» في المتصفح');

        // ═══ Shell حر ═══
        case AgentActionTypes.shellCommand:
          final out = await SystemBridgeService.runShellCommand(
            intent.parameters['command']?.toString() ?? '',
          );
          return _ok(
            intent,
            out.isEmpty ? 'تم التنفيذ (بدون مخرجات)' : 'تم التنفيذ:\n$out',
          );

        // ═══ واجهة التطبيق المفتوح ═══
        case AgentActionTypes.uiClick:
          final viewId = intent.parameters['viewId'] as String?;
          final byText = intent.parameters['text'] as String? ?? '';
          final ok = viewId != null
              ? await AutomationService.findIdAndClick(viewId)
              : await AutomationService.findAndClick(byText);
          if (!ok) {
            return _fail(
              intent,
              'لم يُعثر على العنصر «${byText.isEmpty ? viewId : byText}» — '
              'تأكد من تفعيل خدمة إمكانية الوصول وأن التطبيق المستهدف مفتوح',
            );
          }
          return _ok(intent, 'تم النقر على العنصر المطلوب');

        case AgentActionTypes.uiSetText:
          final ok = await AutomationService.setNodeText(
            viewId: intent.parameters['viewId'] as String?,
            byText: intent.parameters['text'] as String?,
            value: intent.parameters['value']?.toString() ?? '',
          );
          if (!ok) {
            return _fail(
              intent,
              'لم يُعثر على الحقل النصي — تأكد من تفعيل خدمة الإمكانية '
              'وأن التطبيق المستهدف مفتوح',
            );
          }
          return _ok(intent, 'تمت كتابة النص في الحقل');

        case AgentActionTypes.inputTap:
          await SystemBridgeService.inputTap(
            (intent.parameters['x'] as num?)?.toInt() ?? 0,
            (intent.parameters['y'] as num?)?.toInt() ?? 0,
          );
          return _ok(intent, 'تمت النقرة بالإحداثيات');

        case AgentActionTypes.inputText:
          await SystemBridgeService.inputText(
            intent.parameters['text']?.toString() ?? '',
          );
          return _ok(intent, 'تمت كتابة النص');

        default:
          return AgentDispatchResult(
            status: AgentDispatchStatus.unknownCommand,
            message: 'نوع أمر غير مدعوم: ${intent.actionType}',
            intent: intent,
          );
      }
    } on PlatformException catch (e) {
      return _fail(
        intent,
        'خطأ من الطبقة الأصلية [${e.code}]: ${e.message ?? "غير معروف"}',
      );
    } catch (e) {
      return _fail(intent, 'تعذّر التنفيذ: $e');
    }
  }

  // ═══════════════════════════════════════════
  //  الأوامر المعلوماتية — إجابة من الجهاز لا تنفيذ
  // ═══════════════════════════════════════════

  static Future<AgentDispatchResult?> _tryInfoAction(
    AgentActionIntent intent,
  ) async {
    switch (intent.actionType) {
      case AgentActionTypes.deviceInfo:
      case AgentActionTypes.batteryInfo:
      case AgentActionTypes.storageInfo:
        final s = await DeviceKnowledgeService.deviceSnapshot(force: true);
        final text = switch (intent.actionType) {
          AgentActionTypes.batteryInfo => s.batteryPercent >= 0
              ? 'البطارية عند ${s.batteryPercent}% '
                  '${s.isCharging ? 'وهي تشحن الآن' : 'وليست على الشاحن'}.\n'
                  'حالتها: ${s.batteryHealth}.'
              : 'تعذّرت قراءة مستوى البطارية.',
          AgentActionTypes.storageInfo => s.storageTotalBytes > 0
              ? 'المساحة المتبقية '
                  '${DeviceKnowledgeService.humanSize(s.storageFreeBytes)} '
                  'من ${DeviceKnowledgeService.humanSize(s.storageTotalBytes)}.\n'
                  'المستخدم ${s.storageUsedPercent}%.'
              : 'تعذّرت قراءة معلومات التخزين.',
          _ => s.arabicSummary,
        };
        return _ok(intent, text);

      case AgentActionTypes.listApps:
        return _listAppsResult(intent);

      default:
        return null;
    }
  }

  static Future<AgentDispatchResult> _listAppsResult(
    AgentActionIntent intent,
  ) async {
    final includeSystem = intent.parameters['includeSystem'] == true;
    final apps = await DeviceKnowledgeService.listApps(
      includeSystem: includeSystem,
    );
    if (apps.isEmpty) {
      return _fail(intent, 'تعذّر قراءة قائمة التطبيقات من النظام');
    }
    final launchable = apps.where((a) => a.hasLauncher).toList();
    final list = launchable.isEmpty ? apps : launchable;
    final shown = list.take(40).map((a) => '• ${a.appName}').join('\n');
    final more = list.length - 40;
    return _ok(
      intent,
      'لديك ${apps.length} تطبيقاً مثبتاً'
      '${list.length != apps.length ? '، منها ${list.length} يمكن فتحه' : ''}.\n\n'
      '$shown'
      '${more > 0 ? '\n\n… و$more أخرى' : ''}',
    );
  }

  // ═══════════════════════════════════════════
  //  إدارة التطبيقات
  // ═══════════════════════════════════════════

  /// يحلّ معرّف الحزمة من جهاز المستخدم إن لم يكن معروفاً.
  static Future<AgentActionIntent> _ensurePackage(AgentActionIntent intent) async {
    final existing = intent.packageName;
    if (existing != null && existing.isNotEmpty) return intent;
    final name = intent.targetApp ??
        (intent.parameters['appName'] as String?) ??
        (intent.parameters['walletName'] as String?);
    if (name == null || name.isEmpty) return intent;

    final resolved = await DeviceKnowledgeService.resolvePackage(name);
    if (resolved == null) return intent;
    return intent.withParameters(<String, dynamic>{
      'packageName': resolved.packageName,
      'appName': resolved.appName,
      'resolvedFromDevice': true,
    });
  }

  static Future<AgentDispatchResult> _appInfoFromIntent(
    AgentActionIntent intent,
  ) async {
    final resolved = await _ensurePackage(intent);
    final pkg = resolved.packageName;
    if (pkg == null || pkg.isEmpty) {
      return _appNotFound(resolved);
    }
    final d = await DeviceKnowledgeService.appDetails(pkg);
    if (d == null) return _fail(resolved, 'تعذّرت قراءة تفاصيل $pkg');

    final perms = (d['requestedPermissions'] as List?)?.length ?? 0;
    final size = (d['sizeBytes'] as num?)?.toInt() ?? 0;
    return _ok(
      resolved,
      '${d['appName']}\n'
      'المعرّف: $pkg\n'
      'الإصدار: ${d['versionName']} (رمز ${d['versionCode']})\n'
      '${d['isSystem'] == true ? 'تطبيق نظام' : 'تطبيق مستخدم'}'
      '${d['enabled'] == false ? ' — معطّل' : ''}\n'
      'ثُبّت: ${d['installedAt']}  •  آخر تحديث: ${d['updatedAt']}\n'
      'الحجم على القرص: ${DeviceKnowledgeService.humanSize(size)}\n'
      'مسار APK: ${d['apkPath']}\n'
      'مجلد البيانات: ${d['dataDir']}\n'
      'الصلاحيات المطلوبة: $perms',
    );
  }

  static Future<AgentDispatchResult> _appFilesFromIntent(
    AgentActionIntent intent,
  ) async {
    final resolved = await _ensurePackage(intent);
    final pkg = resolved.packageName;
    if (pkg == null || pkg.isEmpty) return _appNotFound(resolved);

    final f = await DeviceKnowledgeService.appFiles(pkg);
    if (f == null) return _fail(resolved, 'تعذّرت قراءة ملفات $pkg');

    final readable = f['readable'] == true;
    final paths = (f['paths'] as Map?) ?? const <String, dynamic>{};
    final sb = StringBuffer('ملفات ${f['packageName']}\n');
    sb.write('مسار APK: ${paths['apk'] ?? '-'}\n');
    sb.write('مجلد البيانات: ${paths['dataDir'] ?? '-'}\n');
    sb.write('المجلد الخارجي: ${paths['external'] ?? '-'}\n');
    final apkSize = (f['apkSizeBytes'] as num?)?.toInt() ?? 0;
    if (apkSize > 0) {
      sb.write('حجم APK: ${DeviceKnowledgeService.humanSize(apkSize)}\n');
    }
    final size = (f['sizeBytes'] as num?)?.toInt() ?? 0;
    if (size > 0) {
      sb.write('الحجم الكلي: ${DeviceKnowledgeService.humanSize(size)}\n');
    }

    if (!readable) {
      sb.write('\n⚠️ ${f['reason'] ?? 'لا يمكن سرد المحتوى'}');
      sb.write('\nلتفعيل القراءة: شغّل Shizuku ثم امنح التطبيق الصلاحية من ⚙️.');
      return AgentDispatchResult(
        status: AgentDispatchStatus.degraded,
        message: sb.toString(),
        intent: resolved,
      );
    }

    final listing = (f['dataDirListing'] as String?) ?? '';
    final du = (f['dataDirSize'] as String?) ?? '';
    final recent = (f['recentFiles'] as String?) ?? '';
    if (du.isNotEmpty) sb.write('\nالحجم: $du');
    if (listing.isNotEmpty) sb.write('\n\nمحتويات مجلد البيانات:\n$listing');
    if (recent.isNotEmpty) sb.write('\n\nآخر ملفات مُعدّلة (7 أيام):\n$recent');

    return _ok(resolved, sb.toString());
  }

  static Future<AgentDispatchResult> _uninstallAppFromIntent(
    AgentActionIntent intent,
  ) async {
    final resolved = await _ensurePackage(intent);
    final pkg = resolved.packageName;
    if (pkg == null || pkg.isEmpty) return _appNotFound(resolved);

    // ACTION_DELETE يفتح حوار النظام الرسمي لإلغاء التثبيت —
    // يعمل بلا أي صلاحية خاصة ولا يمكن تجاوزه، فهو آمن.
    final out = await SystemBridgeService.openSystemIntent('uninstall', extra: pkg);
    return AgentDispatchResult(
      status: AgentDispatchStatus.degraded,
      message: 'فُتح حوار إلغاء تثبيت ${resolved.targetApp ?? pkg}.\n'
          'اضغط «إلغاء التثبيت» للتأكيد النهائي.\n($out)',
      intent: resolved,
    );
  }

  static Future<AgentDispatchResult> _forceStopFromIntent(
    AgentActionIntent intent,
  ) async {
    final resolved = await _ensurePackage(intent);
    final pkg = resolved.packageName;
    if (pkg == null || pkg.isEmpty) return _appNotFound(resolved);
    final out = await SystemBridgeService.forceStopApp(pkg);
    return _ok(resolved, out);
  }

  static Future<AgentDispatchResult> _clearCacheFromIntent(
    AgentActionIntent intent,
  ) async {
    if (intent.parameters['allApps'] == true) {
      final shizuku = await SystemBridgeService.checkShizukuPermission();
      if (!shizuku.isReady) {
        return AgentDispatchResult(
          status: AgentDispatchStatus.failed,
          message: 'مسح كاش كل التطبيقات يتطلب Shizuku.\n'
              'أو اطلب تطبيقاً بعينه: «امسح كاش واتساب».',
          intent: intent,
        );
      }
      final out = await SystemBridgeService.runShellCommand(
        'pm trim-caches 999999999999 2>&1; echo "مُسحت الذاكرة المؤقتة"',
      );
      return _ok(intent, out);
    }
    final resolved = await _ensurePackage(intent);
    final pkg = resolved.packageName;
    if (pkg == null || pkg.isEmpty) return _appNotFound(resolved);
    final out = await SystemBridgeService.clearAppCache(pkg);
    return _ok(resolved, out);
  }

  // ═══════════════════════════════════════════
  //  الملفات
  // ═══════════════════════════════════════════

  static Future<AgentDispatchResult> _listFilesResult(
    AgentActionIntent intent,
  ) async {
    final path = (intent.parameters['path'] as String?) ?? '/sdcard';
    final label = (intent.parameters['label'] as String?) ?? path;
    final shizuku = await SystemBridgeService.checkShizukuPermission();

    if (!shizuku.isReady) {
      // بديل بلا Shizuku: نفتح عارض ملفات النظام على المسار
      final out = await SystemBridgeService.openSystemIntent('files', extra: path);
      return AgentDispatchResult(
        status: AgentDispatchStatus.degraded,
        message: 'سرد محتوى «$label» يحتاج Shizuku.\n'
            'فتحت لك مدير الملفات على المسار نفسه.\n'
            'المسار: $path\n($out)',
        intent: intent,
      );
    }

    final out = await SystemBridgeService.runShellCommand(
      'ls -la ${_quote(path)} 2>&1 | head -60',
    );
    return _ok(intent, 'محتويات $label:\n${out.trim()}');
  }

  static Future<AgentDispatchResult> _findFileResult(
    AgentActionIntent intent,
  ) async {
    final query = (intent.parameters['query'] as String?) ?? '';
    final path = (intent.parameters['path'] as String?) ?? '/sdcard';
    if (query.isEmpty) return _fail(intent, 'لم تُحدد كلمة البحث');

    final shizuku = await SystemBridgeService.checkShizukuPermission();
    if (!shizuku.isReady) {
      return AgentDispatchResult(
        status: AgentDispatchStatus.failed,
        message: 'البحث في ملفات الجهاز يتطلب Shizuku (يقرأ مسارات محمية).\n'
            'فعّل Shizuku ثم أعد الطلب — أو استخدم مدير الملفات مباشرة.',
        intent: intent,
      );
    }

    // نؤمّن كلمة البحث ضد حقن الأوامر
    final safeQuery = query.replaceAll(RegExp(r'''[;&|`$\n\r'"\\]'''), '');
    if (safeQuery.trim().isEmpty) {
      return _fail(intent, 'كلمة البحث تحوي رموزاً غير مسموحة');
    }
    final out = await SystemBridgeService.runShellCommand(
      'find ${_quote(path)} -iname ${_quote('*$safeQuery*')} '
      '2>/dev/null | head -40',
    );
    if (out.trim().isEmpty || out.contains('No such file')) {
      return _ok(intent, 'لم أجد ملفات تطابق «$safeQuery» داخل $path.');
    }
    return _ok(intent, 'نتائج البحث عن «$safeQuery» في $path:\n${out.trim()}');
  }

  // ═══════════════════════════════════════════
  //  فتح التطبيقات
  // ═══════════════════════════════════════════

  static Future<AgentDispatchResult> _launchAppFromIntent(
    AgentActionIntent intent,
  ) async {
    // 1) حلّ معرّف الحزمة من الجهاز إن لم يكن معروفاً
    final resolved = await _ensurePackage(intent);
    final packageName = resolved.packageName;

    if (packageName == null || packageName.isEmpty) {
      return _appNotFound(resolved);
    }

    // 2) المسار الأساسي: Shizuku → monkey/am start (موثوق دائماً)
    final shizuku = await SystemBridgeService.checkShizukuPermission();
    if (shizuku.isReady) {
      await SystemBridgeService.launchApp(packageName);
      return _launchOk(resolved, packageName);
    }

    // 3) المسار البديل بلا Shizuku: نيّة LAUNCHER قياسية
    //    (تعمل على أي جهاز لأن التطبيق المثبت يعلن نشاطه الرئيسي)
    final out = await SystemBridgeService.openSystemIntent(
      'launchPackage',
      extra: packageName,
    );
    if (out.startsWith('نيّة غير مدعومة')) {
      return AgentDispatchResult(
        status: AgentDispatchStatus.failed,
        message: 'لم أتمكن من فتح ${resolved.targetApp ?? packageName}.\n'
            'السبب: Shizuku غير مفعّل والجسر لا يدعم مسار النيّات البديل.\n'
            'فعّل Shizuku من ⚙️ لفتح التطبيقات بشكل موثوق.',
        intent: resolved,
      );
    }
    return AgentDispatchResult(
      status: AgentDispatchStatus.degraded,
      message: '${_launchMessage(resolved, packageName)}\n'
          '(فُتح عبر نيّة النظام — فعّل Shizuku للتحكم الأعمق)',
      intent: resolved,
    );
  }

  static AgentDispatchResult _launchOk(
    AgentActionIntent intent,
    String packageName,
  ) {
    if (intent.actionType == AgentActionTypes.payment) {
      return _ok(
        intent,
        'تم فتح ${intent.targetApp ?? packageName} — '
        'أكمل خطوات التحويل يدوياً أو عبر محرك الأتمتة',
      );
    }
    return _ok(intent, _launchMessage(intent, packageName));
  }

  static String _launchMessage(AgentActionIntent intent, String packageName) =>
      'تم فتح ${intent.targetApp ?? packageName}';

  /// ردّ موحّد عندما لا يُوجد التطبيق على الجهاز — يقترح البدائل.
  static AgentDispatchResult _appNotFound(AgentActionIntent intent) {
    final name = intent.targetApp ??
        intent.parameters['appName'] ??
        'التطبيق';
    return AgentDispatchResult(
      status: AgentDispatchStatus.failed,
      message: 'لم أجد «$name» بين التطبيقات المثبتة على جهازك.\n'
          'قل «ما هي التطبيقات المثبتة؟» لترى الأسماء الدقيقة كما يقرأها '
          'النظام، ثم اطلبه باسمه.',
      intent: intent,
    );
  }

  // ═══════════════════════════════════════════
  //  أدوات
  // ═══════════════════════════════════════════

  /// يغلّف نتيجة أمر Shell: إن فشل بسبب غياب الشيزوكو يفتح شاشة النظام.
  static Future<AgentDispatchResult> _wrapShell(
    AgentActionIntent intent,
    String shellOutput,
    String successMessage, {
    String? fallbackKey,
  }) async {
    final failedByShizuku = shellOutput.contains('Shizuku') ||
        shellOutput.contains('SHIZUKU') ||
        shellOutput.contains('SecurityException') ||
        shellOutput.contains('exitCode: 1') ||
        shellOutput.contains('Permission Denial');

    if (!failedByShizuku) return _ok(intent, successMessage);

    if (fallbackKey == null) {
      return AgentDispatchResult(
        status: AgentDispatchStatus.failed,
        message: '$successMessage تعذّر.\n$shellOutput\n\n'
            'فعّل Shizuku ثم أعد المحاولة — أو بدّل الأمر يدوياً من الإعدادات.',
        intent: intent,
      );
    }

    final out = await SystemBridgeService.openSystemIntent(fallbackKey);
    return AgentDispatchResult(
      status: AgentDispatchStatus.degraded,
      message: '$successMessage يحتاج Shizuku.\n'
          'فتحت لك صفحة الإعدادات المناسبة لتبديلها يدوياً.\n($out)',
      intent: intent,
    );
  }

  /// يحسب نسبة الصوت المطلوبة، مع دعم التغيير النسبي (+/- خطوة).
  static int? _resolveVolumePercent(AgentActionIntent intent) {
    final p = intent.parameters['percent'];
    if (p is num) return p.toInt();
    // التغيير النسبي يحتاج قراءة المستوى الحالي — نفوّضه للطبقة الأصلية
    return null;
  }

  static String _navigationLabel(String target) => switch (target) {
        'home' => 'عُدنا إلى الشاشة الرئيسية',
        'recents' => 'فُتحت قائمة التطبيقات الأخيرة',
        _ => 'عُدنا خطوة للخلف',
      };

  static String _mediaLabel(String op) => switch (op) {
        'pause' => 'أُوقفت الوسائط مؤقتاً',
        'next' => 'انتقلنا للمقطع التالي',
        'prev' => 'عدنا للمقطع السابق',
        'stop' => 'أُوقفت الوسائط',
        _ => 'بدأ تشغيل الوسائط',
      };

  static String _settingsPageLabel(String page) => switch (page) {
        'wifi' => 'الواي فاي',
        'data' => 'بيانات الجوال',
        'bluetooth' => 'البلوتوث',
        'apps' => 'التطبيقات',
        'battery' => 'البطارية',
        'storage' => 'التخزين',
        'sound' => 'الصوت',
        'display' => 'الشاشة',
        'brightness' => 'السطوع',
        'security' => 'الأمان',
        'accounts' => 'الحسابات',
        'location' => 'الموقع',
        'notifications' => 'الإشعارات',
        'accessibility' => 'إمكانية الوصول',
        'date' => 'التاريخ والوقت',
        'developer' => 'خيارات المطور',
        'assistant' => 'المساعد الرقمي',
        _ => 'الإعدادات',
      };

  /// تأمين مسار/قيمة لأمر Shell.
  static String _quote(String value) =>
      "'${value.replaceAll("'", r"'\''")}'";

  static AgentDispatchResult _ok(AgentActionIntent intent, String message) =>
      AgentDispatchResult(
        status: AgentDispatchStatus.executed,
        message: message,
        intent: intent,
      );

  static AgentDispatchResult _fail(AgentActionIntent intent, String message) =>
      AgentDispatchResult(
        status: AgentDispatchStatus.failed,
        message: message,
        intent: intent,
      );

  /// ملخص العملية الحساسة المعروض في بطاقة التأكيد.
  static String _confirmationSummary(AgentActionIntent intent) {
    final parts = <String>[
      if ((intent.targetApp ?? '').isNotEmpty)
        'العملية عبر: ${intent.targetApp}',
      if (intent.parameters['amount'] != null)
        'المبلغ: ${intent.parameters['amount']}',
      if (intent.parameters['phoneNumber'] != null)
        'الرقم: ${intent.parameters['phoneNumber']}',
      if (intent.parameters['packageName'] != null)
        'الحزمة: ${intent.parameters['packageName']}',
      if (intent.parameters['command'] != null)
        'الأمر: ${intent.parameters['command']}',
      if (intent.isScheduled) 'الوقت: ${intent.scheduledTime}',
    ];
    if (parts.isEmpty) {
      return switch (intent.actionType) {
        AgentActionTypes.rebootDevice => 'إعادة تشغيل الجهاز — سيُغلق كل شيء مفتوح',
        _ => 'عملية حساسة تتطلب تأكيداً',
      };
    }
    return parts.join('  •  ');
  }
}
