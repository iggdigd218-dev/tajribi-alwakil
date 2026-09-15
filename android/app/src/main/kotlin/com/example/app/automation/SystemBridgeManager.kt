package com.example.app.automation

import android.content.pm.PackageManager
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
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

    private val mainHandler = Handler(Looper.getMainLooper())

    /** منفّذ أوامر Shell على خيط منفصل عن واجهة المستخدم. */
    private val shellExecutor: ExecutorService = Executors.newCachedThreadPool()

    private var channel: MethodChannel? = null

    /**
     * تسجيل الجسر على محرك Flutter الحالي.
     * يُستدعى من `MainActivity.configureFlutterEngine()`.
     */
    @JvmStatic
    fun register(context: android.content.Context, messenger: BinaryMessenger) {
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
                Shizuku.removeRequestPermissionListener(this)
                postMain { onResult(grantResult == PackageManager.PERMISSION_GRANTED) }
            }
        }
        Shizuku.addRequestPermissionListener(listener)
        try {
            Shizuku.requestPermission(SHIZUKU_REQUEST_CODE)
        } catch (e: Exception) {
            Shizuku.removeRequestPermissionListener(listener)
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

