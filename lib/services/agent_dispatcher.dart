import 'package:flutter/services.dart';

import '../models/agent_action_intent.dart';
import 'automation_service.dart';
import 'scheduler_service.dart';
import 'system_bridge_service.dart';

/// حالات نتيجة التنفيذ.
enum AgentDispatchStatus { executed, scheduled, needsConfirmation, failed, unknownCommand }

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
}

/// المفرّق والمنفّذ المركزي (المرحلة 4).
///
/// يستقبل [AgentActionIntent] ويوجّهه تلقائياً إلى الخدمة الصحيحة:
///
///  - نيّة مجدولة بوقت مستقبلي → SchedulerService.scheduleTask().
///  - أمر فوري للنظام (شبكة/مكالمة/أوامر shell) → SystemBridgeService.
///  - تفاعل مع واجهة تطبيق → AutomationService (Accessibility).
///  - العمليات المالية → تتطلب تأكيداً صريحاً قبل أي تنفيذ.
class AgentDispatcher {
  AgentDispatcher._();

  /// تنفيذ نيّة واحدة.
  ///
  /// [confirmed] يجب أن يكون true لعمليات requiresConfirmation —
  /// الواجهة تعرض بطاقة تأكيد وتستدعي التنفيذ مجدداً بعد موافقة المستخدم.
  static Future<AgentDispatchResult> execute(
    AgentActionIntent intent, {
    bool confirmed = false,
  }) async {
    try {
      // ── 1) البوابة الأمنية: العمليات المالية (حتى المجدولة منها)
      //     لا تُنفَّذ إلا بتأكيد صريح.
      if (intent.requiresConfirmation && !confirmed) {
        return AgentDispatchResult(
          status: AgentDispatchStatus.needsConfirmation,
          message: _confirmationSummary(intent),
          intent: intent,
        );
      }

      // ── 2) مهمة مجدولة بمستقبل → SchedulerService
      if (intent.isScheduled) {
        final ok = await SchedulerService.scheduleTask(
          intent.id,
          intent.scheduledTime!,
          intent.actionType,
          intent.parameters,
        );
        return AgentDispatchResult(
          status:
              ok ? AgentDispatchStatus.scheduled : AgentDispatchStatus.failed,
          message: ok
              ? 'سيتم تنفيذ "${intent.rawText}" في الموعد المحدد'
              : 'فشلت جدولة المهمة — تحقق من صلاحية التنبيهات الدقيقة',
          intent: intent,
        );
      }

      // ── 3) التنفيذ الفوري حسب نوع الأمر
      switch (intent.actionType) {
        case AgentActionTypes.toggleWifi:
          final enable = intent.parameters['enable'] == true;
          await SystemBridgeService.toggleWifi(enable);
          return _ok(intent, 'تم ${enable ? "تفعيل" : "تعطيل"} الواي فاي');

        case AgentActionTypes.toggleMobileData:
          final enable = intent.parameters['enable'] == true;
          await SystemBridgeService.toggleMobileData(enable);
          return _ok(intent, 'تم ${enable ? "تفعيل" : "تعطيل"} بيانات الجوال');

        case AgentActionTypes.call:
          await SystemBridgeService.dialCall(
            intent.parameters['phoneNumber']?.toString() ?? '',
            slotIndex: (intent.parameters['slotIndex'] as num?)?.toInt() ?? 0,
          );
          return _ok(intent, 'جارٍ بدء الاتصال...');

        case AgentActionTypes.openApp:
        case AgentActionTypes.payment:
          return await _launchAppFromIntent(intent);

        case AgentActionTypes.shellCommand:
          final output = await SystemBridgeService.runShellCommand(
            intent.parameters['command']?.toString() ?? '',
          );
          return _ok(
            intent,
            output.isEmpty ? 'تم التنفيذ (بدون مخرجات)' : 'تم التنفيذ:\n$output',
          );

        case AgentActionTypes.uiClick:
          final viewId = intent.parameters['viewId'] as String?;
          final byText = intent.parameters['text'] as String? ?? '';
          final ok = viewId != null
              ? await AutomationService.findIdAndClick(viewId)
              : await AutomationService.findAndClick(byText);
          if (!ok) {
            return _fail(
              intent,
              'لم يُعثر على العنصر — تأكد من تفعيل خدمة الإمكانية '
              'وأن التطبيق المستهدف مفتوح',
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
  //  أدوات داخلية
  // ═══════════════════════════════════════════

  static Future<AgentDispatchResult> _launchAppFromIntent(
    AgentActionIntent intent,
  ) async {
    final packageName = intent.parameters['packageName'] as String?;
    if (packageName == null || packageName.isEmpty) {
      return AgentDispatchResult(
        status: AgentDispatchStatus.failed,
        message: 'لم يُعرف معرّف حزمة "${intent.targetApp}" — '
            'أضِفه إلى خريطة التطبيقات في IntentParserService',
        intent: intent,
      );
    }
    await SystemBridgeService.launchApp(packageName);

    if (intent.actionType == AgentActionTypes.payment) {
      return _ok(
        intent,
        'تم فتح ${intent.targetApp} — أكمل خطوات التحويل يدوياً أو '
        'عبر محرك الأتمتة',
      );
    }
    return _ok(intent, 'تم فتح ${intent.targetApp ?? packageName}');
  }

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

  /// ملخص العملية المالية المعروض في بطاقة التأكيد.
  static String _confirmationSummary(AgentActionIntent intent) {
    final parts = <String>[
      if ((intent.targetApp ?? '').isNotEmpty)
        'العملية عبر: ${intent.targetApp}',
      if (intent.parameters['amount'] != null)
        'المبلغ: ${intent.parameters['amount']}',
      if (intent.parameters['phoneNumber'] != null)
        'الرقم: ${intent.parameters['phoneNumber']}',
      if (intent.isScheduled) 'الوقت: ${intent.scheduledTime}',
    ];
    return parts.isEmpty ? 'عملية مالية' : parts.join('  •  ');
  }
}
