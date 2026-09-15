package com.example.app.automation

import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.BatteryManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.StatFs
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * جسر «معرفة الجهاز» — يجعل الوكيل يعرف جهازه فعلياً.
 *
 * يعطي الوكيل ثلاثة أشياء كان يفتقدها:
 *  1. **جرد التطبيقات المثبتة** (الاسم الظاهر + معرّف الحزمة + الإصدار +
 *     نظامي/مستخدم + حجم + هل هو مُعطَّل) — عبر PackageManager، فلا يحتاج
 *     Shizuku ولا أي صلاحية خاصة.
 *  2. **حقائق الجهاز الحيّة** (بطارية، تخزين، إصدار أندرويد، حالة الشاشات
 *     والصلاحيات) ليتمكن من الإجابة عن «كم البطارية؟» و«هل الشيزوكو شغال؟».
 *  3. **ملفات التطبيقات ومساراتها** — ما يُقرأ عبر PackageManager مباشرة
 *     (مسار APK، مجلد البيانات، مجلد الكاش) بلا صلاحيات، وما يتطلب
 *     uid=shell (حجم المجلد، سرد الملفات) يمر عبر [SystemBridgeManager].
 *
 * القناة: "com.example.app/device_knowledge"
 *
 * ملاحظة أداء: جرد كل التطبيقات (مع الأحجام) بطيء على الأجهزة التي فيها
 * مئات التطبيقات، لذلك يعمل على خيط خلفي ويُخزَّن في ذاكرة التخزين المؤقت
 * مع طابع زمني، وتُستخدم نسخة خفيفة (بلا أحجام) عند الطلب السريع.
 */
object DeviceKnowledgeBridge : MethodChannel.MethodCallHandler {

    const val CHANNEL = "com.example.app/device_knowledge"

    /** مهلة صلاحية جرد التطبيقات في الذاكرة المؤقتة. */
    private const val CACHE_TTL_MS = 5 * 60 * 1000L

    private val mainHandler = Handler(Looper.getMainLooper())
    private val io: ExecutorService = Executors.newFixedThreadPool(2)

    private var context: Context? = null
    private var channel: MethodChannel? = null

    // ── ذاكرة مؤقتة للجرد ──
    @Volatile private var cachedApps: List<Map<String, Any?>>? = null
    @Volatile private var cacheTime: Long = 0L
    @Volatile private var cacheWithSizes: Boolean = false

    @JvmStatic
    fun register(ctx: Context, messenger: BinaryMessenger) {
        context = ctx.applicationContext
        channel = MethodChannel(messenger, CHANNEL).also {
            it.setMethodCallHandler(this)
        }
    }

    // ═══════════════════════════════════════════
    //  1) جرد التطبيقات المثبتة
    // ═══════════════════════════════════════════

    /**
     * قائمة التطبيقات المثبتة.
     *
     * @param includeSystem تضمين تطبيقات النظام (false = تطبيقات المستخدم فقط)
     * @param withSizes     حساب حجم كل تطبيق على القرص (بطيء — يمرر على المجلدات)
     */
    @SuppressLint("QueryPermissionsNeeded")
    fun listApps(includeSystem: Boolean, withSizes: Boolean): List<Map<String, Any?>> {
        val ctx = context ?: return emptyList()
        val pm = ctx.packageManager

        val now = System.currentTimeMillis()
        val cached = cachedApps
        if (cached != null &&
            (now - cacheTime) < CACHE_TTL_MS &&
            (cacheWithSizes || !withSizes)
        ) {
            return if (includeSystem) cached
            else cached.filter { it["isSystem"] != true }
        }

        val installed = pm.getInstalledApplications(PackageManager.GET_META_DATA)
        val out = ArrayList<Map<String, Any?>>(installed.size)

        for (info in installed) {
            val isSystem = (info.flags and ApplicationInfo.FLAG_SYSTEM) != 0 ||
                (info.flags and ApplicationInfo.FLAG_UPDATED_SYSTEM_APP) != 0
            if (!includeSystem && isSystem) continue

            val label = try {
                pm.getApplicationLabel(info).toString()
            } catch (e: Exception) {
                info.packageName
            }

            var versionName = ""
            var versionCode = 0L
            try {
                val pi = pm.getPackageInfo(info.packageName, 0)
                versionName = pi.versionName ?: ""
                versionCode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                    pi.longVersionCode
                } else {
                    @Suppress("DEPRECATION")
                    pi.versionCode.toLong()
                }
            } catch (_: Exception) {
            }

            val enabled = try {
                val state = pm.getApplicationEnabledSetting(info.packageName)
                state != PackageManager.COMPONENT_ENABLED_STATE_DISABLED &&
                    state != PackageManager.COMPONENT_ENABLED_STATE_DISABLED_USER &&
                    state != PackageManager.COMPONENT_ENABLED_STATE_DISABLED_UNTIL_USED
            } catch (_: Exception) {
                // لم يُضبط explicitly → الحالة الافتراضية = مفعّل
                info.enabled
            }

            var installTime = 0L
            var updateTime = 0L
            try {
                val pi = pm.getPackageInfo(info.packageName, 0)
                installTime = pi.firstInstallTime
                updateTime = pi.lastUpdateTime
            } catch (_: Exception) {
            }

            val launcher = try {
                pm.getLaunchIntentForPackage(info.packageName) != null
            } catch (_: Exception) {
                false
            }

            val entry = LinkedHashMap<String, Any?>().apply {
                put("packageName", info.packageName)
                put("appName", label)
                put("isSystem", isSystem)
                put("enabled", enabled)
                put("hasLauncher", launcher)
                put("versionName", versionName)
                put("versionCode", versionCode)
                put("installedAt", isoTime(installTime))
                put("updatedAt", isoTime(updateTime))
                // المسارات — متاحة عبر PackageManager بلا أي صلاحية خاصة
                put("apkPath", info.publicSourceDir ?: "")
                put("dataDir", info.dataDir ?: "")
                put("cacheDir", info.dataDir?.let { "$it/cache" } ?: "")
                put("externalDir", "/sdcard/Android/data/${info.packageName}")
                if (withSizes) {
                    put("sizeBytes", appSize(info))
                }
            }
            out.add(entry)
        }

        // ترتيب أبجدي على الاسم الظاهر — يسهّل العرض والبحث
        out.sortBy { (it["appName"] as? String)?.lowercase() ?: "" }

        cachedApps = out
        cacheTime = System.currentTimeMillis()
        cacheWithSizes = withSizes
        return if (includeSystem) out else out.filter { it["isSystem"] != true }
    }

    /** حجم التطبيق على القرص: APK + مجلد البيانات (يتطلب صلاحية قراءة). */
    private fun appSize(info: ApplicationInfo): Long {
        var total = 0L
        try {
            val apk = File(info.publicSourceDir ?: return 0L)
            if (apk.exists()) total += apk.length()
        } catch (_: Exception) {
        }
        try {
            val data = File(info.dataDir ?: return total)
            if (data.canRead()) total += dirSize(data, maxDepth = 3)
        } catch (_: Exception) {
        }
        return total
    }

    /** حجم مجلد بالبايت — بعمق محدود حتى لا يعلق على أشجار ضخمة. */
    private fun dirSize(dir: File, maxDepth: Int): Long {
        if (maxDepth < 0 || !dir.exists() || !dir.canRead()) return 0L
        var total = 0L
        val files = try {
            dir.listFiles() ?: return 0L
        } catch (_: Exception) {
            return 0L
        }
        for (f in files) {
            total += if (f.isDirectory) dirSize(f, maxDepth - 1) else f.length()
        }
        return total
    }

    /**
     * بحث ذكي عن تطبيق بالاسم الظاهر أو معرّف الحزمة.
     *
     * يقبل نصاً عربياً أو إنجليزياً ويطابقه بثلاث درجات:
     *  1. تطابق تام (يساوي).
     *  2. يحتوي (الاسم الظاهر يحوي النص أو العكس).
     *  3. كلمة مفتاحية من معرّف الحزمة («واتساب» → com.whatsapp لا يطابق،
     *     لكن «whatsapp» يطابق) — لذلك تُجرَّب الأجزاء أيضاً.
     */
    fun findApp(query: String): List<Map<String, Any?>> {
        val q = normalizeArabic(query.trim())
        if (q.isEmpty()) return emptyList()
        val apps = listApps(includeSystem = true, withSizes = false)

        val exact = apps.filter {
            normalizeArabic(it["appName"] as? String ?: "") == q ||
                (it["packageName"] as? String ?: "").equals(q, ignoreCase = true)
        }
        if (exact.isNotEmpty()) return exact

        val contains = apps.filter {
            val name = normalizeArabic(it["appName"] as? String ?: "")
            val pkg = (it["packageName"] as? String ?: "").lowercase()
            name.contains(q) || q.contains(name) && name.length > 2 ||
                pkg.contains(q.lowercase()) ||
                pkg.split('.').any { part ->
                    part.length > 2 && q.lowercase().contains(part)
                }
        }
        // تطبيقات المستخدم أولاً — هي المقصودة غالباً
        return contains
            .sortedBy { if (it["isSystem"] == true) 1 else 0 }
            .take(25)
    }

    /** تفاصيل تطبيق واحد + ملفاته (المسارات تحتاج Shizuku لسرد محتواها). */
    fun appDetails(packageName: String): Map<String, Any?>? {
        val ctx = context ?: return null
        val app = listApps(includeSystem = true, withSizes = true)
            .firstOrNull { it["packageName"] == packageName }
            ?: return null

        val out = LinkedHashMap<String, Any?>(app)

        // الصلاحيات المطلوبة (حتى 20 — للعرض لا للحصر الكامل)
        val perms = try {
            val pi = ctx.packageManager.getPackageInfo(
                packageName, PackageManager.GET_PERMISSIONS
            )
            (pi.requestedPermissions?.take(20)?.toList() ?: emptyList<String>())
        } catch (_: Exception) {
            emptyList<String>()
        }
        out["requestedPermissions"] = perms

        // الأنشطة القابلة للتشغيل
        val activities = try {
            val ri = ctx.packageManager.queryIntentActivities(
                Intent(Intent.ACTION_MAIN).setPackage(packageName), 0
            )
            ri.map { it.activityInfo.name }.take(10)
        } catch (_: Exception) {
            emptyList<String>()
        }
        out["launcherActivities"] = activities

        // ما يمكن قراءته بلا Shizuku: حجم APK نفسه
        out["apkSizeBytes"] = try {
            File(app["apkPath"] as? String ?: "").let { if (it.exists()) it.length() else 0L }
        } catch (_: Exception) { 0L }

        // هل الشيزوكو متاح لسرد الملفات الداخلية؟
        out["shizukuReady"] = SystemBridgeManager.isPermissionGranted()

        // أوامر Shell الجاهزة لسرد ملفات هذا التطبيق (تُنفَّذ لاحقاً إن توفرت الصلاحية)
        val dataDir = app["dataDir"] as? String ?: ""
        out["fileCommands"] = mapOf(
            "listDataDir" to "ls -la $dataDir 2>&1 | head -50",
            "duDataDir" to "du -sh $dataDir 2>&1",
            "listCache" to "ls -la $dataDir/cache 2>&1 | head -30",
            "listExternal" to "ls -la /sdcard/Android/data/$packageName 2>&1 | head -30",
            "duExternal" to "du -sh /sdcard/Android/data/$packageName 2>&1",
            "findRecent" to "find $dataDir -type f -mtime -7 2>/dev/null | head -40"
        )

        return out
    }

    // ═══════════════════════════════════════════
    //  2) حقائق الجهاز الحيّة
    // ═══════════════════════════════════════════

    /** لقطة شاملة لحالة الجهاز — تُستخدم للإجابة الفورية بلا إنترنت. */
    fun deviceSnapshot(): Map<String, Any?> {
        val ctx = context ?: return emptyMap()

        // البطارية
        var level = -1
        var charging = false
        var batteryHealth = ""
        try {
            val bm = ctx.getSystemService(Context.BATTERY_SERVICE) as? BatteryManager
            level = bm?.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY) ?: -1
            val intent = ctx.registerReceiver(
                null, IntentFilter(Intent.ACTION_BATTERY_CHANGED)
            )
            if (intent != null) {
                val status = intent.getIntExtra(BatteryManager.EXTRA_STATUS, -1)
                charging = status == BatteryManager.BATTERY_STATUS_CHARGING ||
                    status == BatteryManager.BATTERY_STATUS_FULL
                batteryHealth = when (
                    intent.getIntExtra(BatteryManager.EXTRA_HEALTH, -1)
                ) {
                    BatteryManager.BATTERY_HEALTH_GOOD -> "جيدة"
                    BatteryManager.BATTERY_HEALTH_OVERHEAT -> "مرتفعة الحرارة"
                    BatteryManager.BATTERY_HEALTH_DEAD -> "تالفة"
                    BatteryManager.BATTERY_HEALTH_OVER_VOLTAGE -> "جهد زائد"
                    BatteryManager.BATTERY_HEALTH_COLD -> "باردة"
                    else -> "غير معروفة"
                }
            }
        } catch (_: Exception) {
        }

        // التخزين
        var totalBytes = 0L
        var freeBytes = 0L
        try {
            val stat = StatFs(File("/data").absolutePath)
            totalBytes = stat.totalBytes
            freeBytes = stat.availableBytes
        } catch (_: Exception) {
        }

        val counts = try {
            val all = ctx.packageManager.getInstalledApplications(0)
            val system = all.count {
                (it.flags and ApplicationInfo.FLAG_SYSTEM) != 0 ||
                    (it.flags and ApplicationInfo.FLAG_UPDATED_SYSTEM_APP) != 0
            }
            mapOf("total" to all.size, "system" to system, "user" to (all.size - system))
        } catch (_: Exception) {
            mapOf("total" to 0, "system" to 0, "user" to 0)
        }

        return LinkedHashMap<String, Any?>().apply {
            put("model", "${Build.MANUFACTURER} ${Build.MODEL}")
            put("manufacturer", Build.MANUFACTURER)
            put("brand", Build.BRAND)
            put("device", Build.DEVICE)
            put("androidVersion", Build.VERSION.RELEASE)
            put("sdkInt", Build.VERSION.SDK_INT)
            put("batteryPercent", level)
            put("isCharging", charging)
            put("batteryHealth", batteryHealth)
            put("storageTotalBytes", totalBytes)
            put("storageFreeBytes", freeBytes)
            put("storageUsedPercent",
                if (totalBytes > 0) ((totalBytes - freeBytes) * 100 / totalBytes) else 0)
            put("appCounts", counts)
            put("isDefaultAssistant", isDefaultAssistant(ctx))
            put("overlayPermission", canDrawOverlays(ctx))
            put("exactAlarmAllowed", ScheduleManager.isExactAlarmAllowed(ctx))
            put("shizukuRunning", SystemBridgeManager.isShizukuRunning())
            put("shizukuGranted", SystemBridgeManager.isPermissionGranted())
            put("accessibilityEnabled", AgentAccessibilityService.isRunning)
            put("foregroundServiceRunning", AgentForegroundService.isRunning)
            put("currentTime", isoTime(System.currentTimeMillis()))
            put("timezone", java.util.TimeZone.getDefault().displayName)
        }
    }

    private fun isDefaultAssistant(ctx: Context): Boolean {
        val flat = Settings.Secure.getString(
            ctx.contentResolver, "voice_interaction_service"
        ) ?: return false
        return flat.contains(ctx.packageName)
    }

    private fun canDrawOverlays(ctx: Context): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            Settings.canDrawOverlays(ctx)
        } else true
    }

    // ═══════════════════════════════════════════
    //  3) أدوات
    // ═══════════════════════════════════════════

    /** تطبيع عربي خفيف للمقارنة: همزات + تشكيل + تاء مربوطة + أرقام هندية. */
    private fun normalizeArabic(input: String): String {
        var t = input
        val eastern = "٠١٢٣٤٥٦٧٨٩۰۱۲۳۴۵۶۷۸۹"
        for (i in 0..9) t = t.replace(eastern[i].toString(), i.toString())
        t = t.replace('أ', 'ا').replace('إ', 'ا').replace('آ', 'ا').replace('ة', 'ه')
        t = t.replace(Regex("[\\u064B-\\u0652\\u0670\\u0640]"), "")
        t = t.replace(Regex("\\s+"), " ")
        return t.trim().lowercase(Locale.ROOT)
    }

    private fun isoTime(millis: Long): String {
        if (millis <= 0L) return ""
        return try {
            SimpleDateFormat("yyyy-MM-dd", Locale.US).format(Date(millis))
        } catch (_: Exception) { "" }
    }

    /** تحويل بايت إلى نص مقروء بالعربية. */
    @JvmStatic
    fun humanSize(bytes: Long): String {
        if (bytes <= 0) return "0 بايت"
        val units = arrayOf("بايت", "كيلوبايت", "ميجابايت", "جيجابايت", "تيرابايت")
        var value = bytes.toDouble()
        var unit = 0
        while (value >= 1024 && unit < units.size - 1) {
            value /= 1024.0
            unit++
        }
        val formatted = if (value >= 100) "%.0f".format(value) else "%.1f".format(value)
        return "$formatted ${units[unit]}"
    }

    // ═══════════════════════════════════════════
    //  القناة
    // ═══════════════════════════════════════════

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {

            // ── سريع: يُنفَّذ فوراً على خيط القناة (بلا أحجام) ──
            "deviceSnapshot" -> result.success(deviceSnapshot())

            "findApp" -> {
                val q = call.argument<String>("query")
                if (q.isNullOrBlank()) {
                    result.error("INVALID_ARGUMENTS", "الوسيط 'query' مطلوب", null)
                } else {
                    result.success(findApp(q))
                }
            }

            // ── بطيء: على خيط خلفي ──
            "listApps" -> runAsync(result) {
                listApps(
                    includeSystem = call.argument<Boolean>("includeSystem") ?: false,
                    withSizes = call.argument<Boolean>("withSizes") ?: false
                )
            }

            "appDetails" -> runAsync(result) {
                val pkg = call.argument<String>("packageName")
                    ?: throw IllegalArgumentException("الوسيط 'packageName' مطلوب")
                appDetails(pkg)
                    ?: throw IllegalArgumentException("التطبيق غير مثبّت: $pkg")
            }

            "appFiles" -> runAsync(result) {
                val pkg = call.argument<String>("packageName")
                    ?: throw IllegalArgumentException("الوسيط 'packageName' مطلوب")
                val details = appDetails(pkg)
                    ?: throw IllegalArgumentException("التطبيق غير مثبّت: $pkg")
                if (!SystemBridgeManager.isPermissionGranted()) {
                    // بلا Shizuku: نعيد المسارات فقط مع شرح السبب
                    mapOf(
                        "packageName" to pkg,
                        "readable" to false,
                        "reason" to "سرد محتوى المجلدات يتطلب Shizuku — " +
                            "المسارات معروفة لكن محتواها محمي بصلاحية النظام",
                        "paths" to mapOf(
                            "apk" to details["apkPath"],
                            "dataDir" to details["dataDir"],
                            "external" to "/sdcard/Android/data/$pkg"
                        ),
                        "apkSizeBytes" to details["apkSizeBytes"],
                        "commands" to details["fileCommands"]
                    )
                } else {
                    val cmds = details["fileCommands"] as Map<*, *>
                    mapOf(
                        "packageName" to pkg,
                        "readable" to true,
                        "paths" to mapOf(
                            "apk" to details["apkPath"],
                            "dataDir" to details["dataDir"],
                            "external" to "/sdcard/Android/data/$pkg"
                        ),
                        "apkSizeBytes" to details["apkSizeBytes"],
                        "sizeBytes" to details["sizeBytes"],
                        "dataDirListing" to safeShell(cmds["listDataDir"] as? String ?: ""),
                        "dataDirSize" to safeShell(cmds["duDataDir"] as? String ?: ""),
                        "externalListing" to safeShell(cmds["listExternal"] as? String ?: ""),
                        "recentFiles" to safeShell(cmds["findRecent"] as? String ?: "")
                    )
                }
            }

            "invalidateCache" -> {
                cachedApps = null
                cacheTime = 0L
                result.success(true)
            }

            else -> result.notImplemented()
        }
    }

    private fun safeShell(command: String): String = try {
        SystemBridgeManager.executeShellCommand(command)
    } catch (e: Exception) {
        "[تعذّر التنفيذ] ${e.message}"
    }

    private fun runAsync(result: MethodChannel.Result, block: () -> Any?) {
        io.execute {
            try {
                val value = block()
                postMain { result.success(value) }
            } catch (e: Exception) {
                postMain {
                    result.error("DEVICE_KNOWLEDGE_ERROR", e.message ?: "خطأ غير معروف", null)
                }
            }
        }
    }

    private fun postMain(block: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) block()
        else mainHandler.post(block)
    }
}
