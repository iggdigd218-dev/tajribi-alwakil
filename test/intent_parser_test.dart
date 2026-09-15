import 'package:flutter_test/flutter_test.dart';

import 'package:agent_automation/models/agent_action_intent.dart';
import 'package:agent_automation/services/intent_parser_service.dart';
import 'package:agent_automation/services/offline_assistant.dart';

/// اختبارات المحلل العربي المحلي — تعمل **دون إنترنت ودون أي قناة أصلية**.
///
/// هذه هي الطبقة التي يعتمد عليها التطبيق عندما يكون الموصل غائباً،
/// لذلك دقتها هي ما يقرر هل التطبيق «يتفاعل بشكل طبيعي» أم لا.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('الشبكة — واي فاي وبيانات', () {
    final cases = <String, String>{
      'شغل الواي فاي': AgentActionTypes.toggleWifi,
      'افتح wifi': AgentActionTypes.toggleWifi,
      'طفي الشبكة': AgentActionTypes.toggleWifi,
      'اقفل الواي فاي': AgentActionTypes.toggleWifi,
      'شغل البيانات': AgentActionTypes.toggleMobileData,
      'اطفئ النت': AgentActionTypes.toggleMobileData,
      'عطل انترنت الجوال': AgentActionTypes.toggleMobileData,
      'شغل بيانات الهاتف': AgentActionTypes.toggleMobileData,
    };
    cases.forEach((text, expected) {
      test('«$text» → $expected', () {
        final i = IntentParserService.parseLocal(text);
        expect(i, isNotNull, reason: 'فشل فهم: $text');
        expect(i!.actionType, expected);
        final enable = i.parameters['enable'];
        expect(enable, isA<bool>(), reason: 'لم تُستخرج enable من: $text');
        final shouldEnable = RegExp(r'(شغل|افتح|فعل)').hasMatch(text);
        expect(enable, shouldEnable, reason: 'اتجاه خاطئ في: $text');
      });
    });

    test('الأرقام العربية-الهندية تُطبَّع', () {
      // «٥» يجب أن تُفهم كـ 5
      final i = IntentParserService.parseLocal('اطفئ البيانات بعد ٥ دقائق');
      expect(i, isNotNull);
      expect(i!.isScheduled, isTrue);
      final diff = i.scheduledTime!.difference(DateTime.now());
      expect(diff.inMinutes, inInclusiveRange(3, 5));
    });

    test('التشكيل لا يكسر الفهم', () {
      final i = IntentParserService.parseLocal('شَغِّل الوَاي فَاي');
      expect(i, isNotNull);
      expect(i!.actionType, AgentActionTypes.toggleWifi);
    });
  });

  group('البلوتوث ووضع الطيران والكشاف', () {
    test('شغل البلوتوث', () {
      final i = IntentParserService.parseLocal('شغل البلوتوث');
      expect(i, isNotNull);
      expect(i!.actionType, AgentActionTypes.toggleBluetooth);
      expect(i.parameters['enable'], true);
    });

    test('البلوتوث لا يُخلط مع الواي فاي', () {
      final i = IntentParserService.parseLocal('اطفئ البلوتوث');
      expect(i!.actionType, AgentActionTypes.toggleBluetooth);
    });

    test('فعل وضع الطيران', () {
      final i = IntentParserService.parseLocal('فعل وضع الطيران');
      expect(i, isNotNull);
      expect(i!.actionType, AgentActionTypes.toggleAirplane);
      expect(i.parameters['enable'], true);
    });

    test('نور الكشاف', () {
      final i = IntentParserService.parseLocal('نور الكشاف');
      expect(i, isNotNull);
      expect(i!.actionType, AgentActionTypes.toggleFlashlight);
      expect(i.parameters['enable'], true);
    });

    test('اطفئ الفلاش', () {
      final i = IntentParserService.parseLocal('اطفئ الفلاش');
      expect(i, isNotNull);
      expect(i!.actionType, AgentActionTypes.toggleFlashlight);
      expect(i.parameters['enable'], false);
    });
  });

  group('السطوع والصوت', () {
    test('خل السطوع 50', () {
      final i = IntentParserService.parseLocal('خل السطوع 50%');
      expect(i, isNotNull);
      expect(i!.actionType, AgentActionTypes.setBrightness);
      expect(i.parameters['percent'], 50);
    });

    test('ارفع السطوع (نسبي)', () {
      final i = IntentParserService.parseLocal('ارفع السطوع');
      expect(i, isNotNull);
      expect(i!.actionType, AgentActionTypes.setBrightness);
      expect(i.parameters['relative'], 'up');
    });

    test('السطوع التلقائي', () {
      final i = IntentParserService.parseLocal('خل السطوع تلقائي');
      expect(i, isNotNull);
      expect(i!.parameters['auto'], true);
    });

    test('اسكت الصوت = كتم', () {
      final i = IntentParserService.parseLocal('اسكت الصوت');
      expect(i, isNotNull);
      expect(i!.actionType, AgentActionTypes.setVolume);
      expect(i.parameters['mute'], true);
      expect(i.parameters['percent'], 0);
    });

    test('الصوت على الثلاثين بالكلمات العربية', () {
      final i = IntentParserService.parseLocal('خل الصوت ثلاثين بالمئة');
      expect(i, isNotNull);
      expect(i!.actionType, AgentActionTypes.setVolume);
      expect(i.parameters['percent'], 30);
    });

    test('ارفع الصوت (نسبي)', () {
      final i = IntentParserService.parseLocal('ارفع الصوت');
      expect(i, isNotNull);
      expect(i!.parameters['relative'], 'up');
    });
  });

  group('الاتصال والرسائل', () {
    test('اتصل بـ 712345678', () {
      final i = IntentParserService.parseLocal('اتصل بـ 712345678');
      expect(i, isNotNull);
      expect(i!.actionType, AgentActionTypes.call);
      expect(i.parameters['phoneNumber'], '712345678');
      expect(i.parameters['slotIndex'], 0);
    });

    test('اتصل من الشريحة 2', () {
      final i = IntentParserService.parseLocal('اتصل بـ 712345678 من الشريحة 2');
      expect(i, isNotNull);
      expect(i!.actionType, AgentActionTypes.call);
      // slotIndex مبني على الصفر: الشريحة 2 = 1
      expect(i.parameters['slotIndex'], 1);
    });

    test('اتصل باسم بلا رقم → لا يُخمَّن', () {
      // لا يمكن حل «أحمد» محلياً دون دفتر جهات الاتصال
      final i = IntentParserService.parseLocal('اتصل بأحمد');
      expect(i?.actionType, isNot(AgentActionTypes.call));
    });

    test('رقم بصيغة دولية مع +', () {
      final i = IntentParserService.parseLocal('كلم +967712345678');
      expect(i, isNotNull);
      expect(i!.actionType, AgentActionTypes.call);
      expect(i.parameters['phoneNumber'], '+967712345678');
    });

    test('ارسل رسالة إلى رقم', () {
      final i = IntentParserService.parseLocal('ارسل رسالة إلى 712345678');
      expect(i, isNotNull);
      expect(i!.actionType, AgentActionTypes.sendMessage);
      expect(i.parameters['phoneNumber'], '712345678');
    });

    test('ارسل ايميل', () {
      final i = IntentParserService.parseLocal('ارسل ايميل إلى ahmed@mail.com');
      expect(i, isNotNull);
      expect(i!.actionType, AgentActionTypes.sendEmail);
      expect(i.parameters['to'], 'ahmed@mail.com');
    });
  });

  group('التطبيقات', () {
    test('افتح واتساب', () {
      final i = IntentParserService.parseLocal('افتح واتساب');
      expect(i, isNotNull);
      expect(i!.actionType, AgentActionTypes.openApp);
      expect(i.targetApp, 'واتساب');
      // الخريطة الاحتياطية تعرف واتساب
      expect(i.parameters['packageName'], 'com.whatsapp');
    });

    test('شغل تطبيق اليوتيوب', () {
      final i = IntentParserService.parseLocal('شغل تطبيق اليوتيوب');
      expect(i, isNotNull);
      expect(i!.actionType, AgentActionTypes.openApp);
    });

    test('«افتح البيانات» ليس فتح تطبيق', () {
      final i = IntentParserService.parseLocal('افتح البيانات');
      // يجب أن يُفهم كشبكة لا كتطبيق اسمه «البيانات»
      expect(i!.actionType, isNot(AgentActionTypes.openApp));
    });

    test('احذف تيك توك → إلغاء تثبيت مع تأكيد', () {
      final i = IntentParserService.parseLocal('احذف تيك توك');
      expect(i, isNotNull);
      expect(i!.actionType, AgentActionTypes.uninstallApp);
      expect(i.targetApp, 'تيك توك');
      expect(i.requiresConfirmation, isTrue, reason: 'عملية هدّامة بلا تأكيد!');
    });

    test('اوقف يوتيوب اجباريا', () {
      final i = IntentParserService.parseLocal('اوقف يوتيوب اجباريا');
      expect(i, isNotNull);
      expect(i!.actionType, AgentActionTypes.forceStopApp);
    });

    test('امسح كاش واتساب', () {
      final i = IntentParserService.parseLocal('امسح كاش واتساب');
      expect(i, isNotNull);
      expect(i!.actionType, AgentActionTypes.clearAppCache);
    });

    test('ما هي التطبيقات المثبتة؟', () {
      final i = IntentParserService.parseLocal('ما هي التطبيقات المثبتة؟');
      expect(i, isNotNull);
      expect(i!.actionType, AgentActionTypes.listApps);
    });

    test('معلومات عن واتساب', () {
      final i = IntentParserService.parseLocal('معلومات عن واتساب');
      expect(i, isNotNull);
      expect(i!.actionType, AgentActionTypes.appInfo);
      expect(i.targetApp, 'واتساب');
    });
  });

  group('الملفات', () {
    test('اعرض ملفات التنزيلات', () {
      final i = IntentParserService.parseLocal('اعرض ملفات التنزيلات');
      expect(i, isNotNull);
      expect(i!.actionType, AgentActionTypes.listFiles);
      expect(i.parameters['path'], '/sdcard/Download');
    });

    test('دور على ملفات pdf', () {
      final i = IntentParserService.parseLocal('دور على ملفات pdf');
      expect(i, isNotNull);
      expect(i!.actionType, AgentActionTypes.findFile);
      expect(i.parameters['query'], contains('pdf'));
    });

    test('مسار صريح يُحترم كما هو', () {
      final i = IntentParserService.parseLocal('اعرض ملفات /sdcard/DCIM');
      expect(i, isNotNull);
      expect(i!.actionType, AgentActionTypes.listFiles);
      expect(i.parameters['path'], '/sdcard/DCIM');
    });

    test('ملفات تطبيق محدد → app_files لا list_files', () {
      final i = IntentParserService.parseLocal('اعرض ملفات واتساب');
      expect(i, isNotNull);
      expect(i!.actionType, AgentActionTypes.appFiles);
      expect(i.targetApp, 'واتساب');
    });
  });

  group('الجدولة', () {
    test('بعد 5 دقائق اطفئ البيانات', () {
      final i = IntentParserService.parseLocal('بعد 5 دقائق اطفئ البيانات');
      expect(i, isNotNull);
      expect(i!.actionType, AgentActionTypes.toggleMobileData);
      expect(i.isScheduled, isTrue);
      expect(i.parameters['enable'], false);
      final diff = i.scheduledTime!.difference(DateTime.now());
      expect(diff.inMinutes, inInclusiveRange(4, 5));
    });

    test('بعد نصف ساعة', () {
      final i = IntentParserService.parseLocal('بعد نصف ساعة شغل الواي فاي');
      expect(i, isNotNull);
      expect(i!.isScheduled, isTrue);
      expect(i.scheduledTime!.difference(DateTime.now()).inMinutes,
          inInclusiveRange(29, 30));
    });

    test('بعد ربع ساعة', () {
      final i = IntentParserService.parseLocal('اطفئ النت بعد ربع ساعة');
      expect(i, isNotNull);
      expect(i!.isScheduled, isTrue);
      expect(i.scheduledTime!.difference(DateTime.now()).inMinutes,
          inInclusiveRange(14, 15));
    });

    test('الساعة 9 مساءً', () {
      final i = IntentParserService.parseLocal('الساعة 9 مساء شغل الواي فاي');
      expect(i, isNotNull);
      expect(i!.isScheduled, isTrue);
      expect(i.scheduledTime!.hour, 21);
    });

    test('غدا الساعة 8 صباحا', () {
      final i = IntentParserService.parseLocal('غدا الساعة 8 صباحا اطفئ البيانات');
      expect(i, isNotNull);
      expect(i!.isScheduled, isTrue);
      // الغد 8:00 بالضبط — مقارنة مطلقة لا تعتمد على ساعة تشغيل الاختبار
      final now = DateTime.now();
      final tomorrow8 = DateTime(now.year, now.month, now.day + 1, 8);
      expect(i.scheduledTime, tomorrow8);
    });

    test('بعد يومين', () {
      final i = IntentParserService.parseLocal('بعد 2 يوم شغل النت');
      expect(i, isNotNull);
      expect(i!.isScheduled, isTrue);
      expect(i.scheduledTime!.difference(DateTime.now()).inDays,
          inInclusiveRange(1, 2));
    });
  });

  group('المحافظ والعمليات المالية', () {
    test('افتح محفظة جوادي', () {
      final i = IntentParserService.parseLocal('افتح محفظة جوادي');
      expect(i, isNotNull);
      expect(i!.actionType, AgentActionTypes.openApp);
      expect(i.targetApp, contains('جوادي'));
      // مجرد فتح المحفظة لا يتطلب تأكيداً
      expect(i.requiresConfirmation, isFalse);
    });

    test('حول 5000 ريال → يتطلب تأكيداً', () {
      final i = IntentParserService.parseLocal('حول 5000 ريال من محفظة جوادي');
      expect(i, isNotNull);
      expect(i!.actionType, AgentActionTypes.payment);
      expect(i.requiresConfirmation, isTrue, reason: 'عملية مالية بلا تأكيد!');
      expect(i.parameters['amount'], 5000);
    });

    test('المبلغ يُستخرج من أول رقم', () {
      final i = IntentParserService.parseLocal('ادفع 1250 من محفظه كاش');
      expect(i, isNotNull);
      expect(i!.actionType, AgentActionTypes.payment);
      expect(i.parameters['amount'], 1250);
    });
  });

  group('الواجهة والوسائط والتنقل', () {
    test('اضغط على زر موافق', () {
      final i = IntentParserService.parseLocal('اضغط على زر موافق');
      expect(i, isNotNull);
      expect(i!.actionType, AgentActionTypes.uiClick);
      expect(i.parameters['text'], 'موافق');
    });

    test('اضغط عند الإحداثيات', () {
      final i = IntentParserService.parseLocal('اضغط على 540 1200');
      expect(i, isNotNull);
      expect(i!.actionType, AgentActionTypes.inputTap);
      expect(i.parameters['x'], 540);
      expect(i.parameters['y'], 1200);
    });

    test('اكتب في خانة البحث: كذا', () {
      final i = IntentParserService.parseLocal('اكتب في خانة البحث: طقس صنعاء');
      expect(i, isNotNull);
      expect(i!.actionType, AgentActionTypes.uiSetText);
      expect(i.parameters['value'], contains('طقس'));
    });

    test('وقف الموسيقى', () {
      final i = IntentParserService.parseLocal('وقف الموسيقى');
      expect(i, isNotNull);
      expect(i!.actionType, AgentActionTypes.mediaControl);
      expect(i.parameters['op'], 'pause');
    });

    test('المقطع التالي', () {
      final i = IntentParserService.parseLocal('شغل الاغنية التالية');
      expect(i, isNotNull);
      expect(i!.actionType, AgentActionTypes.mediaControl);
      expect(i.parameters['op'], 'next');
    });

    test('ارجع للخلف', () {
      final i = IntentParserService.parseLocal('ارجع');
      expect(i, isNotNull);
      expect(i!.actionType, AgentActionTypes.navigateUi);
      expect(i.parameters['target'], 'back');
    });

    test('الشاشة الرئيسية', () {
      final i = IntentParserService.parseLocal('روح للشاشة الرئيسية');
      expect(i, isNotNull);
      expect(i!.actionType, AgentActionTypes.navigateUi);
      expect(i.parameters['target'], 'home');
    });

    test('صور الشاشة', () {
      final i = IntentParserService.parseLocal('صور الشاشة');
      expect(i, isNotNull);
      expect(i!.actionType, AgentActionTypes.screenshot);
    });
  });

  group('أوامر تحتاج تأكيداً', () {
    test('نفذ أمر shell حر → تأكيد', () {
      final i = IntentParserService.parseLocal('نفذ: pm list packages');
      expect(i, isNotNull);
      expect(i!.actionType, AgentActionTypes.shellCommand);
      expect(i.parameters['command'], contains('pm list'));
      expect(i.requiresConfirmation, isTrue,
          reason: 'أمر Shell حرّ بلا تأكيد = ثغرة أمنية');
    });

    test('اعد تشغيل الجهاز → تأكيد', () {
      final i = IntentParserService.parseLocal('اعد تشغيل الجهاز');
      expect(i, isNotNull);
      expect(i!.actionType, AgentActionTypes.rebootDevice);
      expect(i.requiresConfirmation, isTrue);
    });

    test('«اعد تشغيل الواي فاي» ليس إعادة تشغيل للجهاز', () {
      final i = IntentParserService.parseLocal('اعد تشغيل الواي فاي');
      expect(i, isNotNull);
      expect(i!.actionType, isNot(AgentActionTypes.rebootDevice));
    });
  });

  group('المعلومات', () {
    test('كم البطارية', () {
      final i = IntentParserService.parseLocal('كم البطارية');
      expect(i, isNotNull);
      expect(i!.actionType, AgentActionTypes.batteryInfo);
    });

    test('كم المساحة المتبقية', () {
      final i = IntentParserService.parseLocal('كم المساحة المتبقية');
      expect(i, isNotNull);
      expect(i!.actionType, AgentActionTypes.storageInfo);
    });

    test('ابحث في المتصفح عن سعر الذهب', () {
      final i = IntentParserService.parseLocal('ابحث في المتصفح عن سعر الذهب');
      expect(i, isNotNull);
      expect(i!.actionType, AgentActionTypes.searchWeb);
      expect(i.parameters['query'], contains('الذهب'));
    });

    test('افتح رابط', () {
      final i = IntentParserService.parseLocal('افتح https://example.com');
      expect(i, isNotNull);
      expect(i!.actionType, AgentActionTypes.openUrl);
      expect(i.parameters['url'], contains('example.com'));
    });
  });

  group('صفحات الإعدادات', () {
    test('افتح اعدادات الواي فاي', () {
      final i = IntentParserService.parseLocal('افتح اعدادات الواي فاي');
      expect(i, isNotNull);
      // صفحة إعدادات محددة — لا تطبيق اسمه «الواي فاي»
      expect(i!.actionType, AgentActionTypes.openSettingsPage);
      expect(i.parameters['page'], 'wifi');
    });

    test('افتح اعدادات البطارية', () {
      final i = IntentParserService.parseLocal('افتح اعدادات البطارية');
      expect(i, isNotNull);
      expect(i!.actionType, AgentActionTypes.openSettingsPage);
      expect(i.parameters['page'], 'battery');
    });
  });

  group('ما يجب ألا يُفهم خطأً', () {
    test('نص حواري عادي → null (يذهب للسحابة أو للدماغ المحلي)', () {
      expect(IntentParserService.parseLocal('ما رأيك في الحياة؟'), isNull);
      expect(IntentParserService.parseLocal('اشرح لي نظرية النسبية'), isNull);
    });

    test('نص فارغ → null', () {
      expect(IntentParserService.parseLocal(''), isNull);
      expect(IntentParserService.parseLocal('   '), isNull);
    });

    test('«هل واتساب مثبت؟» ليس فتح تطبيق', () {
      final i = IntentParserService.parseLocal('هل واتساب مثبت');
      expect(i?.actionType, isNot(AgentActionTypes.openApp));
    });
  });

  group('الدماغ المحلي دون إنترنت', () {
    test('التحية تُفهم وتردّ طبيعياً', () async {
      final r = await OfflineAssistant.respond('السلام عليكم');
      expect(r.match, isNot(OfflineMatch.none));
      expect(r.reply, isNotEmpty);
      expect(r.reply, contains('سلام'));
    });

    test('صباح الخير', () async {
      final r = await OfflineAssistant.respond('صباح الخير');
      expect(r.match, OfflineMatch.smalltalk);
      expect(r.reply, contains('صباح'));
    });

    test('الشكر', () async {
      final r = await OfflineAssistant.respond('شكرا لك');
      expect(r.match, OfflineMatch.smalltalk);
      expect(r.reply, isNotEmpty);
    });

    test('من أنت؟', () async {
      final r = await OfflineAssistant.respond('من أنت');
      expect(r.match, OfflineMatch.smalltalk);
      expect(r.reply, contains('وكيل'));
    });

    test('ماذا تستطيع؟ — يعدد القدرات', () async {
      final r = await OfflineAssistant.respond('ماذا تستطيع');
      expect(r.match, OfflineMatch.smalltalk);
      expect(r.reply.length, greaterThan(100));
    });

    test('الوقت يُجاب محلياً', () async {
      final r = await OfflineAssistant.respond('كم الساعة الآن');
      expect(r.match, OfflineMatch.deviceKnowledge);
      expect(r.reply, contains(':'));
    });

    test('الحساب يعمل محلياً', () async {
      final r = await OfflineAssistant.respond('كم 15 × 4');
      expect(r.match, OfflineMatch.deviceKnowledge);
      expect(r.reply, contains('60'));
    });

    test('قسمة على صفر لا تنهار', () async {
      final r = await OfflineAssistant.respond('كم 5 ÷ 0');
      expect(r.reply, contains('صفر'));
    });

    test('أمر غير مفهوم → اعتراف + اقتراحات (لا طريق مسدود)', () async {
      final r = await OfflineAssistant.respond('اشرح لي ميكانيكا الكم');
      expect(r.match, OfflineMatch.none);
      expect(r.reply, isNotEmpty);
      // يجب أن يقترح صياغات تعمل، لا أن يقول «لم أفهم» فقط
      expect(r.reply, contains('جرّب'));
    });

    test('«اتصل بأحمد» بلا رقم → يشرح ما ينقص', () async {
      final r = await OfflineAssistant.respond('اتصل بأحمد');
      expect(r.reply, contains('الرقم'));
    });
  });

  group('تشخيص أعطال الموصل', () {
    test('401 = مصادقة', () {
      expect(
        OfflineAssistant.classifyError('invalid api key', statusCode: 401),
        ConnectorFailure.auth,
      );
    });

    test('429 = تجاوز الحد', () {
      expect(
        OfflineAssistant.classifyError('rate limit exceeded', statusCode: 429),
        ConnectorFailure.rateLimit,
      );
    });

    test('404 = موديل غير موجود', () {
      expect(
        OfflineAssistant.classifyError('model_not_found', statusCode: 404),
        ConnectorFailure.model,
      );
    });

    test('500 = عطل خادم', () {
      expect(
        OfflineAssistant.classifyError('internal error', statusCode: 503),
        ConnectorFailure.server,
      );
    });

    test('SocketException = شبكة', () {
      expect(
        OfflineAssistant.classifyError('SocketException: Failed host lookup'),
        ConnectorFailure.network,
      );
    });

    test('Timeout = مهلة', () {
      expect(
        OfflineAssistant.classifyError('TimeoutException after 30s'),
        ConnectorFailure.timeout,
      );
    });

    test('كل نوع عطل له إرشاد قابل للتنفيذ', () {
      for (final f in ConnectorFailure.values) {
        expect(OfflineAssistant.adviceFor(f), isNotEmpty,
            reason: 'لا إرشاد لـ $f');
        expect(f.arabic, isNotEmpty, reason: 'لا وصف عربي لـ $f');
      }
    });
  });

  group('سلامة النموذج المركزي', () {
    test('كل أنواع الأوامر معروفة', () {
      for (final t in AgentActionTypes.all) {
        expect(AgentActionTypes.isKnown(t), isTrue);
      }
    });

    test('نوع مجهول يُرفض', () {
      expect(AgentActionTypes.isKnown('self_destruct'), isFalse);
    });

    test('withParameters يحفظ بقية الحقول', () {
      final i = AgentActionIntent(
        id: 'x',
        rawText: 'افتح واتساب',
        actionType: AgentActionTypes.openApp,
        category: ActionCategory.system,
        targetApp: 'واتساب',
      );
      final patched = i.withParameters({'packageName': 'com.whatsapp'});
      expect(patched.id, 'x');
      expect(patched.targetApp, 'واتساب');
      expect(patched.packageName, 'com.whatsapp');
      expect(patched.rawText, 'افتح واتساب');
    });

    test('التحويل إلى JSON والعودة يحفظ البيانات', () {
      final i = AgentActionIntent(
        id: 'y',
        rawText: 'حول 5000',
        actionType: AgentActionTypes.payment,
        category: ActionCategory.payment,
        targetApp: 'جوادي',
        parameters: {'amount': 5000},
        scheduledTime: DateTime.now().add(const Duration(hours: 1)),
        requiresConfirmation: true,
      );
      final back = AgentActionIntent.fromJson(i.toJson());
      expect(back.actionType, AgentActionTypes.payment);
      expect(back.category, ActionCategory.payment);
      expect(back.targetApp, 'جوادي');
      expect(back.parameters['amount'], 5000);
      expect(back.requiresConfirmation, isTrue);
      expect(back.isScheduled, isTrue);
    });
  });
}
