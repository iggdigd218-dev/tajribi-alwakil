# 🤖 وكيل الأتمتة الذكي — دليل التشغيل الكامل

تطبيق Flutter (أندرويد) يفهم الأوامر العربية **نصاً وصوتاً** وينفذها فعلياً على
الهاتف: تشغيل/إيقاف الواي فاي والبيانات، فتح التطبيقات، المكالمات بتوجيه الشريحة،
الجدولة المؤجلة، التفاعل مع واجهات التطبيقات، والرد الحواري عبر Gemini.

---

## 📋 المتطلبات

| الأداة | الإصدار |
|---|---|
| Flutter SDK | 3.19 أو أحدث (مع Dart 3) |
| Android Studio | مع Android SDK 34 + Build Tools |
| الجهاز | أندرويد 7.0 (API 24) فأحدث — حقيقي وليس محاكياً (الخدمات لا تعمل على المحاكي جيداً) |
| تطبيق Shizuku | مثبت على الهاتف (من GitHub أو متجر) |

---

## 🚀 خطوات البناء الأول مرة

```bash
# 1. فك ضغط agent_automation_complete.zip ثم داخل المجلد:
cd agent_automation

# 2. استكمال ملفات المشروع الناقصة (gradle wrapper، الأيقونات، ios/web...)
#    — لا يكتب فوق أي ملف موجود، فقط يضيف الناقص:
flutter create .

# 3. جلب التبعيات:
flutter pub get

# 4. التشغيل (بدون مفتاح سحابي — الأوامر المحلية فقط):
flutter run

#    أو مع مفتاح Gemini (يفعّل المحرك السحابي الحواري):
flutter run --dart-define=GEMINI_API_KEY=AIzaSy...مفتاحك
```

> 💡 البديل: أدخل مفتاح Gemini من داخل التطبيق — ⚙️ الإعدادات ← حقل المفتاح ←
> حفظ. يُخزَّن محلياً في SharedPreferences ويعمل فوراً دون إعادة البناء.

---

## ⚙️ التفعيل على الهاتف (مرة واحدة، بالترتيب)

1. **صلاحية الإشعارات** (أندرويد 13+): تُطلب تلقائياً عند تشغيل الخدمة الخلفية.
2. **خدمة الإمكانية**: الإعدادات ← إمكانية الوصول ← **«محرك الأتمتة»** ← تفعيل.
   (أو انقر شريحة «الإمكانية» الحمراء في أعلى الشات — تفتح الإعدادات مباشرة).
3. **Shizuku**: شغّل تطبيق Shizuku على الهاتف (عبر ADB لاسلكي أو USB أو Root)،
   ثم انقر شريحة Shizuku في الشات وامنح الصلاحية.
4. **التنبيهات الدقيقة** (أندرويد 12+): فعّل «التنبيهات والتذكيرات الدقيقة»
   للتطبيق — ضرورية لدقة الجدولة بالثانية.
5. **الميكروفون**: اضغط 🎙️ في الترويسة (أو مفتاح «الاستماع الدائم» في ⚙️) واسمح.
6. **الخدمة الخلفية**: انقر الشريحة الثالثة «الخدمة» لتشغيلها.

---

## 🎙️ الاستخدام الصوتي

1. اضغط 🎙️ ← قل: **«يا وكيل، شغل الواي فاي»** (الاسم الافتراضي قابل للتعديل من ⚙️).
2. الأوامر السريعة تُفهم محلياً وتُنفَّذ فوراً مع رد صوتي رجالي.
3. الحوار والأوامر المركبة تُرسل لـ Gemini ويُنطق الرد.
4. يعمل الاستماع والشاشة مغلقة (تحت مظلة الخدمة الأمامية + WakeLock).

## ⌨️ أوامر نصية جاهزة للتجربة في الشات

| الأمر | ماذا يحدث |
|---|---|
| `شغل الواي فاي` | تنفيذ فوري عبر Shizuku |
| `اطفئ البيانات` | svc data disable |
| `افتح واتساب` | فتح التطبيق |
| `اتصل بـ 712345678 من الشريحة 2` | مكالمة موجهة للشريحة الثانية |
| `بعد 10 دقائق اطفئ البيانات` | جدولة دقيقة تختبر Doze |
| `الساعة 9 مساء شغل الواي فاي` | جدولة بوقت محدد |
| `حول 5000 من محفظة جوادي` | بطاقة تأكيد مالي ⚠️ قبل التنفيذ |
| `نفذ: svc wifi enable` | أمر Shell حر |

---

## 📁 بنية المشروع

```
agent_automation/
├── pubspec.yaml                          # صفر تبعيات خارجية
├── lib/
│   ├── main.dart                         # نقطة الانطلاق
│   ├── automation/accessibility_bridge.dart   # (م1) جسر الإمكانية
│   ├── models/agent_action_intent.dart        # (م4) نموذج النيات
│   ├── services/
│   │   ├── automation_service.dart       # (م1) واجهة الأتمتة
│   │   ├── system_bridge_service.dart    # (م2) واجهة Shizuku
│   │   ├── scheduler_service.dart        # (م3) واجهة الجدولة
│   │   ├── intent_parser_service.dart    # (م4) المحلل المحلي
│   │   ├── agent_dispatcher.dart         # (م4) المفرّق المركزي
│   │   ├── gemini_service.dart           # (م5) عميل Gemini النقي
│   │   └── voice_service.dart            # (م5) الدورة الصوتية
│   └── ui/agent_chat_screen.dart         # واجهة الشات
└── android/app/src/main/
    ├── AndroidManifest.xml               # كل الصلاحيات والمكونات
    ├── res/xml/accessibility_service_config.xml
    └── kotlin/com/example/app/
        ├── MainActivity.kt               # تسجيل القنوات الأربع
        └── automation/
            ├── AgentAccessibilityService.kt  # (م1)
            ├── AutomationBridge.kt           # (م1)
            ├── SystemBridgeManager.kt        # (م2)
            ├── AgentForegroundService.kt     # (م3+5)
            ├── TaskAlarmReceiver.kt          # (م3)
            ├── ScheduleManager.kt            # (م3)
            ├── VoiceManager.kt               # (م5)
            └── AppSettingsBridge.kt          # (م5b)
```

**القنوات الأربع:** `accessibility_automation` + `system_bridge` + `scheduler`
+ `voice` (+ `settings` لتخزين المفتاح).

---

## ⚠️ ملاحظات مهمة

- **حزم المحافظ اليمنية** في `intent_parser_service.dart` placeholders — استخرج
  الفعلية بـ `adb shell pm list packages | grep -i جوادي` وحدّث الخريطة.
- **توجيه الشريحة** يعتمد على extras غير موثقة رسمياً — السلوك يختلف بين OEMs.
- **توفير البطارية**: بعض الأجهزة (Xiaomi/Oppo/Huawei) تقتل الميكروفون في
  الخلفية — استثنِ التطبيق من «توفير البطارية» في إعدادات الجهاز.
- **الصوت الرجالي**: النبرة 0.88 + فلترة الأصوات الموسومة male؛ على بعض محركات
  TTS يلزم تثبيت/تحديث «Google Speech Services» وصوت العربية من إعداداته.
- **قبل النشر**: أنشئ مفتاح توقيع release، وراجع سياسات Play بخصوص خدمات
  الإمكانية والاستخدام المالي.
- عند تغيير اسم الحزمة عن `com.example.app`: عدّل `namespace` و`applicationId`
  في `android/app/build.gradle` + `package` في ملفات Kotlin + أسماء الخدمات.

---

## 🔍 استكشاف الأخطاء (Logcat)

```
adb logcat -s AgentA11yService SystemBridge ScheduleManager \
             TaskAlarmReceiver AgentFGService VoiceManager AutomationBridge
```
