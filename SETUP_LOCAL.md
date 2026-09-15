# 🛠️ دليل البيئة المحلية — وكيل الأتمتة الذكي

> كيف تُجهَّز هذه البيئة وتبني الـ APK من الصفر.
> كُتب بعد بناء ناجح فعلي في **2026-09-15**.

---

## 0. الخلاصة السريعة

```bash
bash /home/user/build_apk.sh both        # تثبيت الأدوات + بناء debug و release
# أو، إذا كانت الأدوات مثبّتة مسبقاً:
bash /home/user/build_lowmem.sh release  # بناء release فقط (بضبط ذاكرة آمن)
bash /home/user/build_lowmem.sh debug    # بناء debug فقط
```

الناتج يُنسخ دائماً إلى **`tajribi-alwakil/dist/`** (لا إلى `build/` — انظر §4).

---

## 1. قيود البيئة (مهمة جداً)

| المورد | الواقع | الأثر |
|---|---|---|
| **RAM** | 2 GB فقط، **بدون swap** | `android/gradle.properties` يطلب `-Xmx4G -XX:MaxMetaspaceSize=2G` → **مستحيل**، يقتل OOM-killer الـ daemon |
| **`/tmp`** | `tmpfs` بحجم 993 MB (أي من الـ RAM!) | أي بناء يستخدم `/tmp` يسرق من الذاكرة مباشرة |
| **`/home/user`** | مساحة العمل — **تُصفَّر بين الجلسات** وتُستثنى منها `build/` و`node_modules/` وغيرها | الأدوات المثبّتة هنا تتلف/تختفي |
| **صلاحيات root** | `sudo` يعمل، لكن `/opt` و`/srv` غير قابلة للكتابة | نستخدم `/var/tmp` |
| **القرص** | 20 GB حرة على `/` | كافٍ |

### القرارات الناتجة

1. **سلسلة الأدوات في `/var/tmp/toolchain`** — خارج مساحة العمل، فلا تتلف.
2. **كاش Gradle في `/var/tmp/gradle-home`** (`GRADLE_USER_HOME`) — يعيد البناء بسرعة ويوفر إعادة التنزيل.
3. **`TMPDIR=/var/tmp/tmp`** — لتجنّب `tmpfs` الذي يستهلك RAM.
4. **`/var/tmp/gradle-home/gradle.properties` يتجاوز إعدادات المشروع** — لأن خصائص `GRADLE_USER_HOME` أعلى أولوية من `android/gradle.properties`. هكذا نضبط الذاكرة **دون تعديل ملف داخل المستودع**.

---

## 2. إعداد الذاكرة الذي نجح فعلياً

```properties
# /var/tmp/gradle-home/gradle.properties
org.gradle.jvmargs=-Xmx1200m -XX:MaxMetaspaceSize=288m -XX:+UseSerialGC -XX:MinHeapFreeRatio=10 -XX:MaxHeapFreeRatio=20
org.gradle.parallel=false
org.gradle.workers.max=1
org.gradle.caching=true
org.gradle.daemon=true
kotlin.daemon.jvmargs=-Xmx512m -XX:+UseSerialGC -XX:MinHeapFreeRatio=10 -XX:MaxHeapFreeRatio=20
```

**لماذا هذه القيم:**

- `R8` (تقليص الشيفرة في release) يعمل **داخل** Gradle daemon، لذلك daemon يأخذ أكبر حصة (1200m).
- `parallel=false` و`workers.max=1` يمنعان تشغيل أكثر من وحدة ترجمة في آن واحد.
- Kotlin daemon مُصغَّر إلى 512m لأن 14 ملف `.kt` فقط لا تحتاج أكثر.
- ⚠️ `-XX:MaxHeapFreeRatio` يجب أن يكون **≥** `MinHeapFreeRatio` (الافتراضي 40)، وإلا رفض JVM الإقلاع برسالة `MinHeapFreeRatio (40) must be less than or equal to MaxHeapFreeRatio`.

**ميزانية الذاكرة أثناء البناء** (من أصل ~1500 MB متاحة):

```
Gradle daemon        ~1200 MB (يشمل R8)
Kotlin daemon        ~ 512 MB
Dart frontend_server ~ 300 MB
```

---

## 3. الفخاخ التي وقعنا فيها (وحلولها)

### 3.1 OOM-killer يقتل Gradle daemon
**العرض:** `Gradle build daemon disappeared unexpectedly (it may have been killed or may have crashed)`

**السببان اللذان اكتُشفا:**
1. `org.gradle.jvmargs` في المشروع يطلب 6 GB على جهاز فيه 2 GB.
2. **AGP كان ينزّل مكوّنات SDK ناقصة أثناء البناء** (‏`build-tools;33.0.1`) داخل الـ daemon نفسه — التنزيل + فك الضغط يستهلكان الذاكرة في أسوأ لحظة.

**الحل:** تثبيت كل المكوّنات مسبقاً عبر `sdkmanager` (عملية خفيفة منفصلة)، وإفراغ page cache قبل كل بناء:
```bash
sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'
```

### 3.2 `flutter create` يولّد `MainActivity` مكرراً
**العرض:** يُنشأ `android/app/src/main/kotlin/com/example/agent_automation/MainActivity.kt` بينما الـ `namespace` و`applicationId` الحقيقيان هما `com.example.app`.

**الحل:** حذفه بعد `flutter create` — وهو بالضبط ما فعله آخر commit في المستودع (`fix: إصلاح agent_chat_screen بعد تكرار الملف`):
```bash
rm -rf android/app/src/main/kotlin/com/example/agent_automation
```

### 3.3 مجلد `build/` يختفي بين الجلسات
`build/` مستثنى من لقطة مساحة العمل. لذلك **يجب** نسخ الـ APK إلى مكان آخر فور نجاح البناء:
```bash
cp build/app/outputs/flutter-apk/app-release.apk dist/app-release.apk
```

### 3.4 JDK 11 هو الافتراضي في النظام
المشروع يتطلب Java 17 (`JavaVersion.VERSION_17` + AGP 8.1.3). حُلّ بتنزيل Temurin 17 محمولاً وتمريره عبر:
```bash
flutter config --jdk-dir /var/tmp/toolchain/jdk17
```

---

## 4. ما هو مثبّت وأين

| المكوّن | المسار | الإصدار |
|---|---|---|
| Flutter SDK | `/var/tmp/toolchain/flutter` | 3.24.5 stable (Dart 3.5.4) — **نفس إصدار CI** |
| JDK | `/var/tmp/toolchain/jdk17` | Temurin 17.0.20.1 |
| Android SDK | `/var/tmp/toolchain/android-sdk` | platforms;android-34 • build-tools 34.0.0 + 33.0.1 • platform-tools |
| Gradle | `/var/tmp/gradle-home/wrapper/dists` | 8.3 (عبر wrapper) |
| Pub cache | `/var/tmp/pub-cache` | — |
| **الـ APK الناتج** | **`/home/user/tajribi-alwakil/dist/`** | ✅ يبقى في مساحة العمل |

> NDK ‏(`23.1.7779620`) **غير مثبّت ولا حاجة له** — لا يوجد أي كود C/C++ في المشروع، و`ndkVersion = flutter.ndkVersion` في `build.gradle` لا يستدعي تنزيله ما لم تكن هناك مهام native.

---

## 5. نتيجة البناء (موثّقة)

| البناء | الزمن | الحجم | الحالة |
|---|---|---|---|
| `flutter build apk --debug` | 78 ث | 180 MB | ✅ |
| `flutter build apk --release` | 14 ث (مع الكاش) | 45 MB | ✅ |

**تحقق التوقيع** (`apksigner verify --print-certs`):
```
Verifies
Verified using v2 scheme (APK Signature Scheme v2): true
Number of signers: 1
Signer #1 certificate DN: CN=Agent Automation, OU=tajribi-alwakil, O=iggdigd218-dev, L=Sanaa, C=YE
Signer #1 certificate SHA-256: d380a7dd736276303417ef9f7494b814fbe4b37334a9afd09e0c6740d97214d2
```
→ **debug و release موقّعان بنفس الشهادة** (كما ينوي `build.gradle`)، لذا يُثبَّت التحديث فوق النسخة السابقة دون حذف.

**تحقق الحزمة** (`aapt2 dump badging`):
```
package: name='com.example.app' versionCode='4' versionName='1.2.0'
sdkVersion:'24'   targetSdkVersion:'34'
application-label:'وكيل الأتمتة'
```
12 صلاحية + `moe.shizuku.manager.permission.API_V23` (تبعيتا Shizuku مدموجتان فعلاً في `classes.dex`).
APK موحّد (fat) يحتوي `arm64-v8a` و`armeabi-v7a` و`x86_64`.

---

## 6. تغييرات الأمان المُنفَّذة في المستودع

كلمات مرور مفتاح التوقيع كانت **مكتوبة صراحةً داخل `android/app/build.gradle`**.

**قبل:**
```groovy
signingConfigs {
    agent {
        storeFile file("keystore/agent-release.jks")
        storePassword "AgentAuto2026"      // ← في الكود
        keyAlias "agent"
        keyPassword "AgentAuto2026"        // ← في الكود
    }
}
```

**بعد:** يُقرأ من `android/key.properties` (محلي، مستثنى من git) أو من متغيرات البيئة (CI):
```groovy
def prop = { String name -> keystoreProperties.getProperty(name) ?: System.getenv(name) }
storeFile     file(prop("storeFile") ?: "keystore/agent-release.jks")
storePassword prop("storePassword") ?: ""
keyAlias      prop("keyAlias")      ?: "agent"
keyPassword   prop("keyPassword")   ?: ""
```
مع تراجع آمن إلى مفتاح debug إن لم تتوفر الأسرار، حتى لا يفشل البناء:
```groovy
signingConfig = signingConfigs.agent.storePassword ? signingConfigs.agent : signingConfigs.debug
```

**الملفات:**
- `android/key.properties` — الأسرار الحقيقية، **مستثنى من git** (كان `android/key.properties` مضافاً في `.gitignore` أصلاً)
- `android/key.properties.example` — نموذج يُرفع للمستودع
- `.github/workflows/build_apk.yml` — يقرأ الآن `secrets.AGENT_STORE_PASSWORD` و`secrets.AGENT_KEY_PASSWORD`

### ⚠️ ما تبقى عليك فعله
1. أضف السرّين في GitHub → Settings → Secrets and variables → Actions:
   `AGENT_STORE_PASSWORD` و`AGENT_KEY_PASSWORD`.
2. **كلمة المرور `AgentAuto2026` ما زالت في تاريخ git** (`git log -p android/app/build.gradle`). إزالتها من الملف الحالي لا تزيلها من التاريخ. الخيار الأنظف: توليد keystore جديد ورفع تاريخه — لكن هذا **يكسر التوافق مع النسخ المثبّتة** (لن يُقبل التحديث فوقها)، فقراره لك.
3. ملف `agent-release.jks` نفسه **ما زال مرفوعاً في المستودع** (عبر استثناء `!android/app/keystore/agent-release.jks` في `.gitignore`). أُبقي كذلك عمداً لأنه مطلوب للتوقيع الثابت، ومستودعك غير عام النشاط — لكن إن كان المستودع عاماً فأي شخص يملك الملف + كلمة المرور من التاريخ يستطيع توقيع تحديثات باسمك.

---

## 7. إصلاحات إضافية في CI

في `.github/workflows/build_apk.yml`:
1. حذف `MainActivity` المكرر بعد `flutter create` (الفخ §3.2).
2. خطوة `Prepare signing config` تكتب `android/key.properties` من الأسرار.
3. إصدار الـ release يُقرأ من `pubspec.yaml` بدل أن يكون `v1.2.0` مكتوباً يدوياً في 4 مواضع — كان سيتجاهل أي رفع إصدار مستقبلي.

---

## 8. إعادة التجهيز من الصفر

إذا صُفّرت البيئة (اختفى `/var/tmp/toolchain`)، شغّل فقط:
```bash
bash /home/user/build_apk.sh both
```
السكربت **idempotent**: يفحص وجود كل مكوّن عبر ملفاته التنفيذية ويتخطى ما هو موجود، فيعيد التنزيل فقط عند الحاجة (‏~1.1 GB للتنزيل الكامل: Flutter 660 MB + JDK 185 MB + SDK 147 MB + الحزم).

**فحص سريع للبيئة:**
```bash
free -m | head -2                                  # يجب أن تكون available > 1400
ls /var/tmp/toolchain/{flutter/bin/flutter,jdk17/bin/java}   # الأدوات موجودة؟
df -h / | tail -1                                  # القرص
```

## تحديث 2026-09-15 (الجولة الثانية)

### المفتاح المدمج (الحقن الرسمي)
- `GeminiService.builtInApiKey`: مفتاح Groq محقون **زمن الترجمة** عبر
  `--dart-define=AGENT_BUILTIN_GROQ_KEY=...` (تمرره سكربتات البناء تلقائياً) —
  يعمل التطبيق «من العلبة» بلا إعدادات، والمفتاح لا يدخل تاريخ Git أبداً
  (حماية GitHub push protection ترفض دفع مفاتيح Groq الحية).
- الأولوية: مفتاح المستخدم (الإعدادات) > متغير البناء `GEMINI_API_KEY` > المفتاح المدمج.
- المفتاح المدمج يُرسل لمزود Groq فقط (لا يتسرب لمزود آخر).
- الواجهة تعرض «✓ Groq جاهز (مفتاح مدمج)» عندما يعمل بالمدمج.
- ⚠️ أي مفتاح داخل APK قابل للاستخراج — المفتاح المدمج من الفئة المجانية ويُستحسن تدويره دورياً.

### الموديلات (تحديث 2026-09)
- Groq الافتراضي: `qwen/qwen3.8-27b` (اختُبر حياً — يلتزم ببروتوكول JSON للتطبيق؛ `llama-3.3-70b-versatile` سُحب من المنصة).
- Gemini الافتراضي: `gemini-flash-latest` (alias ما زال يعمل؛ `gemini-2.0-flash` أُوقف).

### User-Agent إلزامي
- بوابة Groq (Cloudflare) ترفض UA الافتراضي `Dart/x.x (dart:io)` و`Python-urllib` برمز 403 — اختُبر حياً.
- `GeminiService.userAgent` يُضبط على مستوى HttpClient في كل الطلبات (chat + اختبار الاتصال).

### الصوت العصبي (Edge TTS)
- `lib/services/edge_tts_service.dart`: Microsoft Edge TTS مجاني بلا مفاتيح — WebSocket + رمز DRM (Sec-MS-GEC = SHA-256 وقت Windows مقرباً لـ5 دقائق + رمز العميل)، وصوت `ar-SA-HamedNeural` (بديل `ar-EG-ShakirNeural`).
- SHA-256 منفذة داخلياً بـ Dart خالص (التزام سياسة «بلا حزم خارجية»).
- **حقيقة بروتوكولية مكتشفة بالتقاط الحي**: إطارات الصوت = بايتا نوع `00 80` + ترويسة تنتهي بـ `Path:audio\r\n` وبعدها MP3 **فوراً بلا سطر فارغ**.
- **فخ Dart**: `WebSocket.connect` **يضيف** UA افتراضياً ولا يستبدله — الحل `customClient: HttpClient()..userAgent = ...`.
- الإصدارات المقبولَة من الخادم (2026-09): `1-140.0.3462.56` وما بعدها؛ `1-130.x` مرفوض 403. القائمة مرشحة بالترتيب ويُحفظ الناجح.
- التشغيل: Kotlin `VoiceManager.playAudioFile` (MediaPlayer + طابور + إسكات الميكروفون أثناء النطق + حذف الملف المؤقت بعد البدء).
- `VoiceService.speak()`: عصبي أولاً → أي فشل (لا إنترنت/403/مهلة) → Android TTS تلقائياً. `stopSpeaking()` يوقف المسارين.
- اختبار يدوي من الطرفية: `dart run tool/edge_tts_manual.dart "نصك"`

### المساعد الرقمي الافتراضي
- الخدمات الثلاث مسجلة في Manifest: `AgentVoiceInteractionService` (BIND_VOICE_INTERACTION + meta-data)، `AgentVoiceSessionService`، `AgentRecognitionService` (BIND_RECOGNITION_SERVICE + فلتر RecognitionService).
- `res/xml/voice_interaction_service.xml`: sessionService + recognitionService + supportsAssist + supportsLaunchVoiceAssistFromKeyguard.
- ⚠️ `android:supportsContext` **غير موجودة في إطار أندرويد** (AAPT: attribute not found) — دعم السياق يتحقق بـ `supportsAssist=true`.
- للتفعيل على الجهاز: الإعدادات ← التطبيقات ← التطبيقات الافتراضية ← تطبيق المساعدة الرقمية ← اختيار «وكيل الأتمتة».

### الاختبارات
- `flutter test`: **101/101** (89 محلل الأوامر + 12 لخدمة Edge TTS: متجهات SHA-256 القياسية، رمز DRM وثباته عبر النوافذ، هروب XML، تحليل إطارات الصوت).
- فحص حي للموصلين: `/var/tmp/api_test2.py <GEMINI_KEY> <GROQ_KEY>` (يتضمن اختبار بروتوكول JSON الكامل مع سياق الجهاز).

### APK هذه الجولة
- SHA-256: `7082cfb9240c77c16163b14d65e97cf185873f6d73ed70a94b8cc076e795ff82`
- نفس شهادة التوقيع (ترقية فوق النسخ السابقة بلا فقدان بيانات).
