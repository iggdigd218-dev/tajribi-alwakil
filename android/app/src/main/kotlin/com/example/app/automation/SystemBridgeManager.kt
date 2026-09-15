package com.example.app.automation

import android.content.pm.PackageManager
import android.content.Context
import android.content.Intent
import android.hardware.camera2.CameraManager
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.provider.Settings
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import moe.shizuku.server.IShizukuService
import rikka.shizuku.Shizuku
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * جسر التحكم العميق في النظام عبر Shizuku (المرحلة 2).
 *
 * يوفر:
 *  - فحص حالة Shizuku (هل الخدمة تعمل؟ هل الصلاحية ممنوحة؟).
 *  - طلب الصلاحية عند الحاجة.
 *  - تنفيذ أوامر Shell بصلاحيات shell/root عبر Shizuku.newProcess.
 *  - دوال تنفيذية مباشرة: بيانات الجوال، الواي فاي، فتح التطبيقات،
 *    النقر بالإحداثيات، الكتابة المباشرة، والمكالمات مع تحديد الشريحة.
 *  - قناة MethodChannel باسم "com.example.app/system_bridge" لاستدعاء
 *    كل ما سبق من كود Dart.
 *
 * ملاحظة: الأوامر المنفذة عبر القناة تعمل على خيط خلفي حتى لا تتجمد
 * واجهة Flutter، وتُعاد النتيجة إلى الخيط الرئيسي.
 */
object SystemBridgeManager : MethodChannel.MethodCallHandler {

    /** اسم القناة — يجب أن يطابق الاسم في system_bridge_service.dart */
    const val CHANNEL = "com.example.app/system_bridge"

    private const val TAG = "SystemBridge"
    private const val SHIZUKU_REQUEST_CODE = 1001
    private const val SHELL_TIMEOUT_SECONDS = 20L

    // ── أنواع الأوامر الموحدة (تستخدمها المرحلتان 3 و 4) ──
    const val ACTION_TOGGLE_WIFI = "toggle_wifi"
    const val ACTION_TOGGLE_MOBILE_DATA = "toggle_mobile_data"
    const val ACTION_OPEN_APP = "open_app"
    const val ACTION_CALL = "call"
    const val ACTION_SHELL_COMMAND = "shell_command"
    const val ACTION_INPUT_TAP = "input_tap"
    const val ACTION_INPUT_TEXT = "input_text"
    const val ACTION_UI_CLICK = "ui_click"
    const val ACTION_UI_SET_TEXT = "ui_set_text"

    // ── المرحلة 6: أنواع أوامر إضافية ──
    const val ACTION_TOGGLE_BLUETOOTH = "toggle_bluetooth"
    const val ACTION_TOGGLE_AIRPLANE = "toggle_airplane"
    const val ACTION_TOGGLE_FLASHLIGHT = "toggle_flashlight"
    const val ACTION_SET_BRIGHTNESS = "set_brightness"
    const val ACTION_TOGGLE_ROTATION = "toggle_rotation"
    const val ACTION_SET_VOLUME = "set_volume"
    const val ACTION_SET_DND = "set_dnd"
    const val ACTION_NAVIGATE_UI = "navigate_ui"
    const val ACTION_SCREENSHOT = "screenshot"
    const val ACTION_LOCK_SCREEN = "lock_screen"
    const val ACTION_MEDIA_CONTROL = "media_control"
    const val ACTION_OPEN_URL = "open_url"
    const val ACTION_SEARCH_WEB = "search_web"
    const val ACTION_SEND_MESSAGE = "send_message"
    const val ACTION_SEND_EMAIL = "send_email"
    const val ACTION_OPEN_CAMERA = "open_camera"
    const val ACTION_OPEN_CONTACTS = "open_contacts"
    const val ACTION_OPEN_SETTINGS_PAGE = "open_settings_page"
    const val ACTION_UNINSTALL_APP = "uninstall_app"
    const val ACTION_FORCE_STOP_APP = "force_stop_app"
    const val ACTION_CLEAR_APP_CACHE = "clear_app_cache"

    private val mainHandler = Handler(Looper.getMainLooper())

    /** سياق التطبيق — يُحفظ عند التسجيل لاستخدامه في النيّات والكشاف. */
    private var appContext: Context? = null

    /** منفّذ أوامر Shell على خيط منفصل عن واجهة المستخدم. */
    private val shellExecutor: ExecutorService = Executors.newCachedThreadPool()

    private var channel: MethodChannel? = null

    /**
     * تسجيل الجسر على محرك Flutter الحالي.
     * يُستدعى من `MainActivity.configureFlutterEngine()`.
     */
    @JvmStatic
    fun register(context: android.content.Context, messenger: BinaryMessenger) {
        appContext = context.applicationContext
        channel?.setMethodCallHandler(null)
        channel = MethodChannel(messenger, CHANNEL).also {
            it.setMethodCallHandler(this)
        }
    }

    // ═══════════════════════════════════════════
    //  حالة Shizuku
    // ═══════════════════════════════════════════

    /** هل خدمة Shizuku نفسها تعمل على الجهاز (الـ Binder حي)؟ */
    fun isShizukuRunning(): Boolean = try {
        Shizuku.pingBinder()
    } catch (e: Exception) {
        false
    }

    /** هل منح المستخدم صلاحية Shizuku لهذا التطبيق؟ */
    fun isPermissionGranted(): Boolean = try {
        isShizukuRunning() &&
            Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED
    } catch (e: Exception) {
        false
    }

    /**
     * طلب صلاحية Shizuku — يفتح مربع حوار في تطبيق Shizuku Manager
     * وتعود النتيجة عبر [onResult] (دائماً على الخيط الرئيسي).
     */
    fun requestShizukuPermission(onResult: (Boolean) -> Unit) {
        if (!isShizukuRunning() || Shizuku.isPreV11()) {
            postMain { onResult(false) }
            return
        }
        val listener = object : Shizuku.OnRequestPermissionResultListener {
            override fun onRequestPermissionResult(requestCode: Int, grantResult: Int) {
                Shizuku.removeRequestPermissionResultListener(this)
                postMain { onResult(grantResult == PackageManager.PERMISSION_GRANTED) }
            }
        }
        Shizuku.addRequestPermissionResultListener(listener)
        try {
            Shizuku.requestPermission(SHIZUKU_REQUEST_CODE)
        } catch (e: Exception) {
            Shizuku.removeRequestPermissionResultListener(listener)
            postMain { onResult(false) }
        }
    }

    // ═══════════════════════════════════════════
    //  تنفيذ أوامر Shell عبر Shizuku
    // ═══════════════════════════════════════════

    /**
     * تنفيذ أمر Shell بصلاحيات Shizuku (uid 2000 "shell" أو root)
     * مع قراءة النتيجة كاملة (stdout + stderr).
     *
     * الطريقة العلنية الرسمية في Shizuku API 13.1.5:
     * الحصول على Binder الخدمة عبر [Shizuku.getBinder] ثم استدعاء
     * [IShizukuService.newProcess] الذي يبدأ العملية عن بعد ويعيد
     * عمليةً نقرأ مخرجاتها عبر ParcelFileDescriptor.
     *
     * @throws IllegalStateException إذا لم تكن صلاحية Shizuku ممنوحة.
     */
    fun executeShellCommand(command: String): String {
        if (!isPermissionGranted()) {
            throw IllegalStateException("Shizuku غير مفعّل أو الصلاحية غير ممنوحة للتطبيق")
        }

        val binder = Shizuku.getBinder()
            ?: throw IllegalStateException("خدمة Shizuku غير متصلة (الـ Binder غير متوفر)")

        val service = IShizukuService.Stub.asInterface(binder)
        val remote = service.newProcess(arrayOf("sh", "-c", command), null, null)

        // خيط حارس: يدمّر العملية إن تجاوزت المهلة حتى لا يعلق المتصل
        Thread {
            try {
                Thread.sleep(SHELL_TIMEOUT_SECONDS * 1000)
            } catch (_: InterruptedException) {
            }
            try {
                remote.destroy()
            } catch (_: Exception) {
            }
        }.apply { isDaemon = true }.start()

        return try {
            // AutoCloseInputStream يغلق الـ ParcelFileDescriptor تلقائياً
            val stdout = ParcelFileDescriptor.AutoCloseInputStream(remote.inputStream)
                .use { it.readBytes().toString(Charsets.UTF_8) }
            val stderr = ParcelFileDescriptor.AutoCloseInputStream(remote.errorStream)
                .use { it.readBytes().toString(Charsets.UTF_8) }
            val exitCode = try {
                remote.waitFor()
            } catch (e: Exception) {
                -1
            }
            buildString {
                append(stdout.trim())
                if (stderr.isNotBlank()) append("\n[stderr] ").append(stderr.trim())
                append("\n[exitCode: ").append(exitCode).append(']')
            }.trim()
        } finally {
            try {
                remote.destroy()
            } catch (_: Exception) {
            }
        }
    }

    // ═══════════════════════════════════════════
    //  دوال تنفيذية مباشرة
    // ═══════════════════════════════════════════

    /** تفعيل/تعطيل بيانات الهاتف: svc data enable/disable */
    fun toggleMobileData(enable: Boolean): String =
        executeShellCommand("svc data ${if (enable) "enable" else "disable"}")

    /** تفعيل/تعطيل الواي فاي: svc wifi enable/disable */
    fun toggleWifi(enable: Boolean): String =
        executeShellCommand("svc wifi ${if (enable) "enable" else "disable"}")

    /**
     * فتح أي تطبيق مع تمرير معاملات اختيارية عبر `am start`.
     *
     * - إذا حُدد [activity]: `am start -n package/activity --es k v`
     * - إذا لم يُحدد: نفتح النشاط الرئيسي للتطبيق عبر monkey (موثوق على
     *   جميع الأجهزة ويغنيك عن معرفة اسم النشاط).
     */
    fun launchApp(
        packageName: String,
        activity: String? = null,
        extras: Map<String, String>? = null
    ): String {
        val command = if (!activity.isNullOrBlank()) {
            buildString {
                append("am start -n ").append(shellQuote("$packageName/$activity"))
                extras?.forEach { (key, value) ->
                    append(" --es ").append(shellQuote(key))
                    append(' ').append(shellQuote(value))
                }
            }
        } else {
            "monkey -p $packageName -c android.intent.category.LAUNCHER 1"
        }
        return executeShellCommand(command)
    }

    /** النقر بالإحداثيات عبر `input tap`. */
    fun inputTap(x: Int, y: Int): String =
        executeShellCommand("input tap $x $y")

    /** الكتابة المباشرة عبر `input text` (مع تأمين علامات الاقتباس). */
    fun inputText(text: String): String =
        executeShellCommand("input text ${shellQuote(text)}")

    /**
     * تشغيل اتصال مباشر وتوجيهه لمنفذ الشريحة المحدد.
     *
     * معرفات توجيه الشريحة غير موثقة رسمياً وتختلف بين الشركات المصنعة،
     * لذا نمرر أكثر من extra معروف لزيادة فرص النجاح:
     *  - com.android.phone.extra.slot  (الأكثر شيوعاً: Samsung / MediaTek / معظم الأجهزة)
     *  - simSlot                        (بعض الأجهزة)
     *  - android.telecom.extra.SLOT_ID (AOSP الحديث)
     *
     * @param slotIndex فهرس الشريحة (0 = الشريحة الأولى، 1 = الشريحة الثانية).
     */
    /** يبحث في جهات الاتصال عن اسم (كلي أو جزئي) ويعيد أول رقم مطابق — أو "" */
    fun findContactNumber(name: String): String {
        val ctx = appContext ?: return ""
        val needle = name.trim().lowercase()
        if (needle.isEmpty()) return ""
        if (ctx.checkSelfPermission(android.Manifest.permission.READ_CONTACTS) !=
            PackageManager.PERMISSION_GRANTED
        ) return ""
        val phoneUri =
            android.provider.ContactsContract.CommonDataKinds.Phone.CONTENT_URI
        val dnCol =
            android.provider.ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME
        val numCol =
            android.provider.ContactsContract.CommonDataKinds.Phone.NUMBER
        var best = ""
        try {
            ctx.contentResolver.query(
                phoneUri,
                arrayOf(dnCol, numCol),
                null, null, null,
            )?.use { c ->
                val dnI = c.getColumnIndexOrThrow(dnCol)
                val numI = c.getColumnIndexOrThrow(numCol)
                while (c.moveToNext()) {
                    val dn = c.getString(dnI)?.lowercase()?.trim() ?: continue
                    val num = c.getString(numI)?.trim() ?: continue
                    if (num.isEmpty()) continue
                    if (dn == needle) return num
                    if (best.isEmpty() &&
                        (dn.contains(needle) || needle.contains(dn))
                    ) best = num
                }
            }
        } catch (t: Throwable) {
            Log.w(TAG, "findContactNumber فشل: $t")
        }
        return best
    }

    fun dialCallViaSlot(phoneNumber: String, slotIndex: Int): String {
        val number = phoneNumber.replace(Regex("[^+\\d]"), "")
        if (number.isBlank()) {
            throw IllegalArgumentException("رقم الهاتف غير صالح: $phoneNumber")
        }
        val command = buildString {
            append("am start -a android.intent.action.CALL -d tel:")
            append(shellQuote(number))
            if (slotIndex > 0) {
                append(" --ei com.android.phone.extra.slot ").append(slotIndex)
                append(" --ei simSlot ").append(slotIndex)
                append(" --ei android.telecom.extra.SLOT_ID ").append(slotIndex)
            }
        }
        return executeShellCommand(command)
    }

    // ═══════════════════════════════════════════
    //  المرحلة 6: تنفيذ بلا Shizuku (نيّات + واجهات نظام)
    // ═══════════════════════════════════════════
    //
    // الشيزوكو ليس متاحاً على كل الأجهزة (يتطلب تفعيله يدوياً بعد كل
    // إعادة تشغيل). لذلك كل أمر له **مسار بديل لا يحتاج صلاحية نظام** —
    // يفتح شاشة النظام المناسبة أو يرسل نيّة قياسية، بدل أن يفشل بصمت.
    // هذه الدوال هي تلك المسارات البديلة.

    /**
     * الكشاف عبر CameraManager — **لا يحتاج أي صلاحية خاصة**،
     ويعمل حتى بدون Shizuku.
     */
    fun setFlashlight(enable: Boolean): String {
        val ctx = appContext
            ?: return "سياق التطبيق غير متاح"
        return try {
            if (!ctx.packageManager.hasSystemFeature(
                    PackageManager.FEATURE_CAMERA_FLASH
                )
            ) {
                return "الجهاز لا يملك فلاش"
            }
            val cm = ctx.getSystemService(Context.CAMERA_SERVICE) as? CameraManager
                ?: return "خدمة الكاميرا غير متاحة"
            // نختار أول كاميرا تعلن أن فلاشها متاح
            val id = cm.cameraIdList.firstOrNull { camId ->
                try {
                    cm.getCameraCharacteristics(camId)
                        .get(android.hardware.camera2.CameraCharacteristics
                            .FLASH_INFO_AVAILABLE) == true
                } catch (_: Exception) {
                    false
                }
            } ?: cm.cameraIdList.firstOrNull()
            ?: return "لا توجد كاميرا بكشاف"
            cm.setTorchMode(id, enable)
            if (enable) "أُشعل الكشاف" else "أُطفئ الكشاف"
        } catch (e: Exception) {
            "تعذّر التحكم بالكشاف: ${e.message}"
        }
    }

    /**
     * ضبط مستوى صوت الوسائط.
     *
     * @param percent 0..100 — يُحوَّل إلى مؤشر AudioManager.
     * @param mute    كتم كامل.
     */
    fun setVolume(percent: Int?, mute: Boolean): String {
        val ctx = appContext ?: return "سياق التطبيق غير متاح"
        return try {
            val am = ctx.getSystemService(Context.AUDIO_SERVICE)
                as? android.media.AudioManager
                ?: return "خدمة الصوت غير متاحة"
            val stream = android.media.AudioManager.STREAM_MUSIC
            val max = am.getStreamMaxVolume(stream)
            if (mute) {
                am.setStreamVolume(stream, 0, 0)
                return "كُتم صوت الوسائط"
            }
            val p = (percent ?: 50).coerceIn(0, 100)
            val target = (max * p / 100.0).toInt().coerceIn(0, max)
            am.setStreamVolume(stream, target, 0)
            return "ضُبط صوت الوسائط على $p% ($target من $max)"
        } catch (e: Exception) {
            "تعذّر ضبط الصوت: ${e.message}"
        }
    }

    /**
     * فتح نيّة نظام قياسية — لا تحتاج صلاحية خاصة.
     *
     * المفاتيح المدعومة هي صفحات الإعدادات والوظائف التي يمكن للنظام
     * فتحها مباشرة (wifi/battery/storage/apps/accessibility/... إلخ).
     */
    fun openSystemIntent(key: String, extra: String? = null): String {
        val ctx = appContext ?: return "سياق التطبيق غير متاح"
        val intent: Intent = when (key) {
            // صفحات الإعدادات
            "settings.main" -> Intent(Settings.ACTION_SETTINGS)
            "settings.wifi" -> Intent(Settings.ACTION_WIFI_SETTINGS)
            "settings.data" -> Intent(Settings.ACTION_DATA_ROAMING_SETTINGS)
            "settings.bluetooth" -> Intent(Settings.ACTION_BLUETOOTH_SETTINGS)
            "settings.airplane" -> Intent(Settings.ACTION_AIRPLANE_MODE_SETTINGS)
            "settings.battery" -> Intent(Settings.ACTION_BATTERY_SAVER_SETTINGS)
            "settings.storage" -> Intent(Settings.ACTION_INTERNAL_STORAGE_SETTINGS)
            "settings.apps" -> Intent(Settings.ACTION_APPLICATION_SETTINGS)
            "settings.sound" -> Intent(Settings.ACTION_SOUND_SETTINGS)
            "settings.display" -> Intent(Settings.ACTION_DISPLAY_SETTINGS)
            "settings.brightness" -> Intent(Settings.ACTION_DISPLAY_SETTINGS)
            "settings.security" -> Intent(Settings.ACTION_SECURITY_SETTINGS)
            "settings.accounts" -> Intent(Settings.ACTION_SYNC_SETTINGS)
            "settings.location" -> Intent(Settings.ACTION_LOCATION_SOURCE_SETTINGS)
            "settings.notifications" ->
                Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)
            "settings.accessibility" -> Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)
            "settings.date" -> Intent(Settings.ACTION_DATE_SETTINGS)
            "settings.developer" -> Intent(Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS)
            "settings.assistant" -> Intent(Settings.ACTION_VOICE_INPUT_SETTINGS)
            "settings.overlay" -> Intent(
                Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                Uri.parse("package:${ctx.packageName}")
            )
            "settings.exactAlarm" -> Intent(
                Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM,
                Uri.parse("package:${ctx.packageName}")
            )

            // وظائف النظام
            "camera" -> Intent(android.provider.MediaStore.INTENT_ACTION_STILL_IMAGE_CAMERA)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            "contacts" -> Intent(Intent.ACTION_VIEW, Uri.parse("content://contacts/people"))
            "dialer" -> Intent(Intent.ACTION_DIAL)
            "sms" -> Intent(Intent.ACTION_VIEW, Uri.parse("sms:"))
            "email" -> Intent(Intent.ACTION_SENDTO, Uri.parse("mailto:"))
            "browser" -> Intent(
                Intent.ACTION_VIEW,
                Uri.parse(extra ?: "https://www.google.com")
            )
            "webSearch" -> Intent(
                Intent.ACTION_VIEW,
                Uri.parse(
                    "https://www.google.com/search?q=" +
                        Uri.encode(extra ?: "")
                )
            )
            "maps" -> Intent(
                Intent.ACTION_VIEW,
                Uri.parse("geo:0,0?q=" + Uri.encode(extra ?: ""))
            )
            "share" -> Intent(Intent.ACTION_SEND).apply {
                type = "text/plain"
                putExtra(Intent.EXTRA_TEXT, extra ?: "")
            }
            "uninstall" -> Intent(
                Intent.ACTION_DELETE,
                Uri.parse("package:${extra ?: ""}")
            )
            "appDetails" -> Intent(
                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                Uri.parse("package:${extra ?: ""}")
            )
            "files" -> Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(Uri.parse(extra ?: "/sdcard"), "*/*")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }

            // فتح تطبيق بمعرّف حزمته — المسار البديل عندما لا يتوفر Shizuku.
            // getLaunchIntentForPackage يعيد نشاط LAUNCHER الرسمي للتطبيق،
            // فيعمل على أي جهاز دون أي صلاحية خاصة.
            "launchPackage" -> {
                val pkg = extra ?: return "معرّف الحزمة مطلوب"
                ctx.packageManager.getLaunchIntentForPackage(pkg)
                    ?: return "لا يوجد نشاط رئيسي قابل للفتح في $pkg " +
                        "(قد يكون معطلاً أو تطبيق خدمة)"
            }

            else -> return "نيّة غير مدعومة: $key"
        }

        return try {
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            ctx.startActivity(intent)
            "فُتحت $key"
        } catch (e: Exception) {
            // بعض الصفحات غير موجودة على كل الأجهزة (تختلف حسب الشركة المصنعة)
            "تعذّر فتح $key: ${e.message}"
        }
    }

    /**
     * إرسال رسالة نصية — يفتح تطبيق الرسائل مع الرقم والنص جاهزين.
     *
     * الإرسال الفعلي يتطلب صلاحية SEND_SMS (غير مضمّنة عمداً حتى لا
     * يُرسل شيء دون علم المستخدم) — لذلك نملأ المسودة ونترك الضغط له.
     */
    fun openSmsCompose(phoneNumber: String, body: String): String {
        val ctx = appContext ?: return "سياق التطبيق غير متاح"
        return try {
            val intent = Intent(Intent.ACTION_SENDTO).apply {
                data = Uri.parse("smsto:${phoneNumber.replace(Regex("[^+\\d]"), "")}")
                putExtra("sms_body", body)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            ctx.startActivity(intent)
            "فُتحت مسودة الرسالة إلى $phoneNumber"
        } catch (e: Exception) {
            "تعذّر فتح تطبيق الرسائل: ${e.message}"
        }
    }

    /**
     * فتح محادثة واتساب مباشرة مع رقم — عبر wa.me (يعمل بلا Shizuku).
     * إن لم يكن واتساب مثبتاً يفتح الرابط في المتصفح.
     */
    fun openWhatsAppChat(phoneNumber: String, body: String): String {
        val ctx = appContext ?: return "سياق التطبيق غير متاح"
        val digits = phoneNumber.replace(Regex("\\D"), "")
        val withCountry = if (digits.startsWith("0")) "967${digits.drop(1)}" else digits
        return try {
            val intent = Intent(
                Intent.ACTION_VIEW,
                Uri.parse(
                    "https://wa.me/$withCountry" +
                        (if (body.isNotEmpty()) "?text=${Uri.encode(body)}" else "")
                )
            ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            ctx.startActivity(intent)
            "فُتحت محادثة واتساب مع $phoneNumber"
        } catch (e: Exception) {
            "تعذّر فتح واتساب: ${e.message}"
        }
    }

    // ═══════════════════════════════════════════
    //  قناة التواصل مع Flutter
    // ═══════════════════════════════════════════

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {

            "checkShizukuPermission" -> result.success(
                mapOf(
                    "shizukuRunning" to isShizukuRunning(),
                    "permissionGranted" to isPermissionGranted()
                )
            )

            "requestShizukuPermission" -> {
                if (!isShizukuRunning()) {
                    result.error(
                        "SHIZUKU_NOT_RUNNING",
                        "تطبيق Shizuku غير مشغّل على الجهاز — شغّله أولاً ثم أعد المحاولة",
                        null
                    )
                } else {
                    requestShizukuPermission { granted ->
                        postMain { result.success(granted) }
                    }
                }
            }

            // الأوامر التالية تنفّذ على خيط خلفي ثم تُعاد النتيجة للخيط الرئيسي
            "runShellCommand" -> runOnShellThread(result) {
                val command = call.argument<String>("command")
                    ?: throw IllegalArgumentException("الوسيط 'command' مفقود")
                executeShellCommand(command)
            }

            "setSystemSetting" -> runOnShellThread(result) {
                val setting = call.argument<String>("setting")
                    ?: throw IllegalArgumentException("الوسيط 'setting' مفقود")
                when (setting) {
                    "mobileData" -> {
                        val enable = call.argument<Boolean>("enable") ?: true
                        toggleMobileData(enable)
                    }
                    "wifi" -> {
                        val enable = call.argument<Boolean>("enable") ?: true
                        toggleWifi(enable)
                    }
                    "call" -> {
                        val phone = call.argument<String>("phoneNumber")
                            ?: throw IllegalArgumentException("الوسيط 'phoneNumber' مفقود")
                        dialCallViaSlot(phone, call.argument<Number>("slotIndex")?.toInt() ?: 0)
                    }
                    else -> throw IllegalArgumentException("setting غير مدعوم: $setting")
                }
            }

            "findContactNumber" -> {
                result.success(findContactNumber(call.argument<String>("name") ?: ""))
            }

            "toggleMobileData" -> runOnShellThread(result) {
                toggleMobileData(call.argument<Boolean>("enable") ?: true)
            }

            "toggleWifi" -> runOnShellThread(result) {
                toggleWifi(call.argument<Boolean>("enable") ?: true)
            }

            "launchApp" -> runOnShellThread(result) {
                val packageName = call.argument<String>("packageName")
                    ?: throw IllegalArgumentException("الوسيط 'packageName' مفقود")
                launchApp(
                    packageName,
                    call.argument<String>("activity"),
                    call.argument<Map<String, String>>("extras")
                )
            }

            "inputTap" -> runOnShellThread(result) {
                inputTap(
                    call.argument<Number>("x")?.toInt() ?: 0,
                    call.argument<Number>("y")?.toInt() ?: 0
                )
            }

            "inputText" -> runOnShellThread(result) {
                inputText(call.argument<String>("text") ?: "")
            }

            // ── المرحلة 6: أوامر لا تحتاج Shizuku ──
            "setFlashlight" -> runOnShellThread(result) {
                setFlashlight(call.argument<Boolean>("enable") ?: true)
            }

            "setVolume" -> runOnShellThread(result) {
                setVolume(
                    call.argument<Number>("percent")?.toInt(),
                    call.argument<Boolean>("mute") ?: false
                )
            }

            "openSystemIntent" -> runOnShellThread(result) {
                val key = call.argument<String>("key")
                    ?: throw IllegalArgumentException("الوسيط 'key' مطلوب")
                openSystemIntent(key, call.argument<String>("extra"))
            }

            "openSmsCompose" -> runOnShellThread(result) {
                openSmsCompose(
                    call.argument<String>("phoneNumber") ?: "",
                    call.argument<String>("body") ?: ""
                )
            }

            "openWhatsAppChat" -> runOnShellThread(result) {
                openWhatsAppChat(
                    call.argument<String>("phoneNumber") ?: "",
                    call.argument<String>("body") ?: ""
                )
            }

            // ── المرحلة 6: أوامر تحتاج Shizuku، مع مسار بديل إن غاب ──
            "toggleBluetooth" -> runOnShellThread(result) {
                val enable = call.argument<Boolean>("enable") ?: true
                if (isPermissionGranted()) {
                    // cmd bluetooth_manager: متاح من أندرويد 8 عبر shell
                    executeShellCommand(
                        "cmd bluetooth_manager ${if (enable) "enable" else "disable"}"
                    )
                } else {
                    openSystemIntent("settings.bluetooth") +
                        " (فعّل Shizuku للتحكم المباشر دون فتح الإعدادات)"
                }
            }

            "toggleAirplane" -> runOnShellThread(result) {
                val enable = call.argument<Boolean>("enable") ?: true
                if (isPermissionGranted()) {
                    executeShellCommand(
                        "cmd connectivity airplane-mode " +
                            (if (enable) "enable" else "disable")
                    )
                } else {
                    openSystemIntent("settings.airplane") +
                        " (فعّل Shizuku للتبديل المباشر)"
                }
            }

            "setBrightness" -> runOnShellThread(result) {
                val percent = (call.argument<Number>("percent")?.toInt() ?: 50)
                    .coerceIn(0, 100)
                val auto = call.argument<Boolean>("auto") ?: false
                if (isPermissionGranted()) {
                    val value = if (auto) 1 else 0
                    val level = (255 * percent / 100.0).toInt().coerceIn(0, 255)
                    executeShellCommand(
                        "settings put system screen_brightness_mode $value; " +
                            "settings put system screen_brightness $level; " +
                            "echo \"السطوع الآن $percent%\""
                    )
                } else {
                    openSystemIntent("settings.brightness") +
                        " (فعّل Shizuku للضبط المباشر)"
                }
            }

            "toggleRotation" -> runOnShellThread(result) {
                val orientation = call.argument<String>("orientation")
                val auto = call.argument<Boolean>("auto")
                if (isPermissionGranted()) {
                    val cmd = when {
                        auto != null -> "settings put system accelerometer_rotation " +
                            (if (auto) 1 else 0)
                        orientation == "landscape" ->
                            "settings put system accelerometer_rotation 0; " +
                                "settings put system user_rotation 1"
                        orientation == "portrait" ->
                            "settings put system accelerometer_rotation 0; " +
                                "settings put system user_rotation 0"
                        else -> "echo 'لم يُحدد اتجاه'"
                    }
                    executeShellCommand("$cmd; echo 'ضُبط اتجاه الشاشة'")
                } else {
                    openSystemIntent("settings.display") +
                        " (فعّل Shizuku للضبط المباشر)"
                }
            }

            "setDnd" -> runOnShellThread(result) {
                val enable = call.argument<Boolean>("enable") ?: true
                if (isPermissionGranted()) {
                    executeShellCommand(
                        "cmd notification set_dnd " + (if (enable) "on" else "off")
                    )
                } else {
                    openSystemIntent("settings.sound") +
                        " (فعّل Shizuku للتحكم المباشر)"
                }
            }

            "navigateUi" -> runOnShellThread(result) {
                val target = call.argument<String>("target") ?: "back"
                if (isPermissionGranted()) {
                    val code = when (target) {
                        "home" -> 3
                        "recents" -> 187
                        else -> 4
                    }
                    executeShellCommand("input keyevent $code")
                } else {
                    // بلا Shizuku لا يمكن حقن أحداث النظام
                    "التنقل في الواجهة يتطلب Shizuku — فعّله ثم أعد المحاولة"
                }
            }

            "screenshot" -> runOnShellThread(result) {
                if (isPermissionGranted()) {
                    val path = "/sdcard/Pictures/Screenshots/agent_" +
                        System.currentTimeMillis() + ".png"
                    executeShellCommand(
                        "mkdir -p /sdcard/Pictures/Screenshots; " +
                            "screencap -p $path && echo 'حُفظت اللقطة في $path'"
                    )
                } else {
                    "لقطة الشاشة تتطلب Shizuku — أو استخدم اختصار النظام " +
                        "(زر الطاقة + خفض الصوت)"
                }
            }

            "lockScreen" -> runOnShellThread(result) {
                if (isPermissionGranted()) {
                    executeShellCommand("input keyevent 26")
                } else {
                    "قفل الشاشة يتطلب Shizuku — استخدم زر الطاقة"
                }
            }

            "rebootDevice" -> runOnShellThread(result) {
                if (isPermissionGranted()) {
                    executeShellCommand("svc power reboot || reboot")
                } else {
                    "إعادة تشغيل الجهاز تتطلب Shizuku بصلاحية نظام — " +
                        "استخدم زر الطاقة يدوياً"
                }
            }

            "mediaControl" -> runOnShellThread(result) {
                val op = call.argument<String>("op") ?: "play"
                val code = when (op) {
                    "pause" -> 85      // KEYCODE_MEDIA_PLAY_PAUSE
                    "next" -> 87       // KEYCODE_MEDIA_NEXT
                    "prev" -> 88       // KEYCODE_MEDIA_PREVIOUS
                    "stop" -> 86       // KEYCODE_MEDIA_STOP
                    else -> 126        // KEYCODE_MEDIA_PLAY
                }
                if (isPermissionGranted()) {
                    executeShellCommand("input keyevent $code")
                } else {
                    // بديل بلا Shizuku: نيّة وسائط قياسية
                    val action = when (op) {
                        "pause" -> "com.android.music.musicservicecommand.pause"
                        "next" -> "com.android.music.musicservicecommand.next"
                        "prev" -> "com.android.music.musicservicecommand.previous"
                        else -> "com.android.music.musicservicecommand.play"
                    }
                    try {
                        appContext?.sendBroadcast(
                            Intent(action).putExtra("command", op)
                        )
                        "أُرسل أمر الوسائط ($op)"
                    } catch (e: Exception) {
                        "التحكم بالوسائط يتطلب Shizuku: ${e.message}"
                    }
                }
            }

            "forceStopApp" -> runOnShellThread(result) {
                val pkg = call.argument<String>("packageName")
                    ?: throw IllegalArgumentException("الوسيط 'packageName' مطلوب")
                if (isPermissionGranted()) {
                    executeShellCommand("am force-stop $pkg && echo 'أُوقف $pkg'")
                } else {
                    openSystemIntent("appDetails", pkg) +
                        " — اضغط «إيقاف إجباري» (يتطلب Shizuku للتنفيذ المباشر)"
                }
            }

            "clearAppCache" -> runOnShellThread(result) {
                val pkg = call.argument<String>("packageName")
                    ?: throw IllegalArgumentException("الوسيط 'packageName' مطلوب")
                if (isPermissionGranted()) {
                    executeShellCommand(
                        "pm clear --cache-only $pkg 2>/dev/null || " +
                            "rm -rf /data/data/$pkg/cache/* 2>&1; " +
                            "echo 'مُسحت ذاكرة $pkg المؤقتة'"
                    )
                } else {
                    openSystemIntent("appDetails", pkg) +
                        " — اضغط «التخزين» ثم «مسح ذاكرة التخزين المؤقت»"
                }
            }

            else -> result.notImplemented()
        }
    }

    /**
     * تنفيذ كتلة على خيط الأوامر وإرجاع قيمتها عبر [result]
     * مع التقاط أي استثناء وتحويله إلى result.error.
     */
    private fun runOnShellThread(result: MethodChannel.Result, block: () -> Any?) {
        shellExecutor.execute {
            try {
                val value = block()
                postMain { result.success(value) }
            } catch (e: Exception) {
                postMain {
                    result.error(
                        "SHIZUKU_ERROR",
                        e.message ?: e.javaClass.simpleName,
                        null
                    )
                }
            }
        }
    }

    /** تأمين قيمة داخل علامتي اقتباس مفردتين لاستخدامها بأمان في الأمر. */
    private fun shellQuote(value: String): String =
        "'" + value.replace("'", "'\\''") + "'"

    private fun postMain(block: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) block()
        else mainHandler.post(block)
    }
}

