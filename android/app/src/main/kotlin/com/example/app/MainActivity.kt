package com.example.app

import android.content.Context
import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import com.example.app.automation.AgentForegroundService
import com.example.app.automation.AppSettingsBridge
import com.example.app.automation.AutomationBridge
import com.example.app.automation.DeviceKnowledgeBridge
import com.example.app.automation.FloatingOverlayManager
import com.example.app.automation.ScheduleManager
import com.example.app.automation.SystemBridgeManager
import com.example.app.automation.VoiceManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject

class MainActivity : FlutterActivity() {

    // ───── المرحلة 5: القناة الصوتية ─────
    private var pendingAudioPermissionResult: MethodChannel.Result? = null

    private companion object {
        const val RC_RECORD_AUDIO = 3001
    }

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        requestBatteryExemptionOnce()
    }

    /** يطلب إعفاء التطبيق من تحسينات البطارية مرة واحدة — ضروري على
     *  واجهات Transsion وغيرها لتبقى خدمة الاستماع حية بالشاشة المقفلة. */
    private fun requestBatteryExemptionOnce() {
        try {
            val prefs = getSharedPreferences("agent_settings", Context.MODE_PRIVATE)
            if (prefs.getBoolean("asked_battery", false)) return
            val pm = getSystemService(Context.POWER_SERVICE) as android.os.PowerManager
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.M &&
                !pm.isIgnoringBatteryOptimizations(packageName)
            ) {
                prefs.edit().putBoolean("asked_battery", true).apply()
                startActivity(
                    android.content.Intent(
                        android.provider.Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                        android.net.Uri.parse("package:$packageName"),
                    ).addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK),
                )
            } else {
                prefs.edit().putBoolean("asked_battery", true).apply()
            }
        } catch (e: Exception) {
            android.util.Log.w("MainActivity", "طلب إعفاء البطارية تعذر: ${e.message}")
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        // ───── المرحلة 1: جسر خدمة الأتمتة (AccessibilityService) ─────
        AutomationBridge.register(this, messenger)

        // ───── المرحلة 2: جسر النظام (Shizuku) ─────
        SystemBridgeManager.register(this, messenger)

        // ───── المرحلة 3: جسر الجدولة والمهام الخلفية ─────
        MethodChannel(messenger, "com.example.app/scheduler")
            .setMethodCallHandler { call, result -> handleSchedulerCall(call, result) }

        // ───── المرحلة 5: القناة الصوتية (STT + TTS + Wake-Word) ─────
        val voiceChannel = MethodChannel(messenger, "com.example.app/voice").also {
            it.setMethodCallHandler { call, result -> handleVoiceCall(call, result) }
        }
        VoiceManager.init(this, voiceChannel)

        // ───── المرحلة 5b: جسر الإعدادات (حفظ مفتاح Gemini محلياً) ─────
        AppSettingsBridge.register(this, messenger)

        // ───── المرحلة 6: جسر معرفة الجهاز (التطبيقات المثبتة + ملفاتها + حالة الجهاز) ─────
        DeviceKnowledgeBridge.register(this, messenger)

        // ───── النافذة العائمة + المساعد الافتراضي ─────
        MethodChannel(messenger, "com.example.app/overlay")
            .setMethodCallHandler { call, result -> handleOverlayCall(call, result) }
    }

    /** معالجة استدعاءات القناة الصوتية "com.example.app/voice". */
    private fun handleVoiceCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {

            "setWakeWord" -> {
                val name = call.argument<String>("name")
                if (name.isNullOrBlank()) {
                    result.error("INVALID_ARGUMENTS", "الوسيط 'name' مطلوب", null)
                } else {
                    VoiceManager.setWakeWord(name)
                    result.success(true)
                }
            }

            "getWakeWord" -> result.success(VoiceManager.getWakeWord())

            "hasRecordAudioPermission" -> result.success(hasRecordAudioPermission())

            // يفتح نافذة الصلاحية ويردّ النتيجة عند إغلاقها
            "requestRecordAudioPermission" -> {
                if (hasRecordAudioPermission()) {
                    result.success(true)
                } else {
                    pendingAudioPermissionResult = result
                    requestPermissions(
                        arrayOf(Manifest.permission.RECORD_AUDIO),
                        RC_RECORD_AUDIO
                    )
                }
            }

            "startListening", "startContinuousListening" -> result.success(
                if (hasRecordAudioPermission()) VoiceManager.startListening() else false
            )

            "stopListening" -> {
                VoiceManager.stopListening()
                result.success(true)
            }

            "speak", "speakText" -> {
                VoiceManager.speak(call.arguments as? String ?: "")
                result.success(true)
            }

            // الصوت العصبي (Edge TTS): تشغيل/إيقاف/حالة
            "playAudioFile" -> result.success(
                VoiceManager.playAudioFile(call.arguments as? String ?: "")
            )

            "stopAudioPlayback" -> {
                VoiceManager.stopAudioPlayback()
                result.success(true)
            }

            "isAudioPlaying" -> result.success(VoiceManager.isAudioPlaying())

            "isListening" -> result.success(VoiceManager.isListening())

            else -> result.notImplemented()
        }
    }

    private fun hasRecordAudioPermission(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            checkSelfPermission(Manifest.permission.RECORD_AUDIO) ==
                PackageManager.PERMISSION_GRANTED
        } else {
            true // الصلاحيات تُمنح عند التثبيت قبل أندرويد 6
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == RC_RECORD_AUDIO) {
            val granted = grantResults.isNotEmpty() &&
                grantResults[0] == PackageManager.PERMISSION_GRANTED
            pendingAudioPermissionResult?.success(granted)
            pendingAudioPermissionResult = null
        }
    }

    /** معالجة استدعاءات قناة النافذة العائمة والمساعد الافتراضي. */
    private fun handleOverlayCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {

            "hasOverlayPermission" ->
                result.success(FloatingOverlayManager.canDrawOverlays(this))

            "requestOverlayPermission" -> {
                if (FloatingOverlayManager.canDrawOverlays(this)) {
                    result.success(true)
                    return
                }
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    try {
                        startActivity(
                            Intent(
                                Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                                Uri.parse("package:$packageName")
                            )
                        )
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("OPEN_SETTINGS_FAILED", e.message, null)
                    }
                } else {
                    result.success(true)
                }
            }

            "showOverlay" -> {
                if (!FloatingOverlayManager.canDrawOverlays(this)) {
                    result.error(
                        "OVERLAY_PERMISSION",
                        "صلاحية العرض فوق التطبيقات غير ممنوحة",
                        null
                    )
                    return
                }
                FloatingOverlayManager.show(this)
                result.success(true)
            }

            "hideOverlay" -> {
                FloatingOverlayManager.hide()
                result.success(true)
            }

            "isOverlayShowing" -> result.success(FloatingOverlayManager.isShowing())

            "isDefaultAssistant" -> result.success(isDefaultAssistant())

            "openAssistantSettings" -> {
                try {
                    startActivity(Intent(Settings.ACTION_VOICE_INPUT_SETTINGS))
                    result.success(true)
                } catch (e: Exception) {
                    try {
                        startActivity(Intent(Settings.ACTION_SETTINGS))
                        result.success(true)
                    } catch (inner: Exception) {
                        result.error("OPEN_SETTINGS_FAILED", inner.message, null)
                    }
                }
            }

            else -> result.notImplemented()
        }
    }

    /** هل حُدِّد هذا التطبيق مساعداً رقمياً افتراضياً في إعدادات النظام؟ */
    private fun isDefaultAssistant(): Boolean {
        val flat = Settings.Secure.getString(
            contentResolver,
            "voice_interaction_service"
        ) ?: return false
        return flat.contains(packageName)
    }

    /** معالجة استدعاءات قناة الجدولة "com.example.app/scheduler". */
    private fun handleSchedulerCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {

            "scheduleTask" -> {
                val taskId = call.argument<String>("taskId")
                val triggerAtMillis = call.argument<Number>("triggerAtMillis")?.toLong()
                val actionType = call.argument<String>("actionType")
                if (taskId == null || triggerAtMillis == null || actionType == null) {
                    result.error(
                        "INVALID_ARGUMENTS",
                        "taskId / triggerAtMillis / actionType مطلوبة",
                        null
                    )
                    return
                }
                val payloadMap = call.argument<Map<String, Any>>("payload") ?: emptyMap()
                val payloadJson = JSONObject(payloadMap).toString()
                result.success(
                    ScheduleManager.scheduleExactTask(
                        this, taskId, triggerAtMillis, actionType, payloadJson
                    )
                )
            }

            "cancelTask" -> {
                val taskId = call.argument<String>("taskId")
                if (taskId == null) {
                    result.error("INVALID_ARGUMENTS", "taskId مطلوب", null)
                    return
                }
                result.success(ScheduleManager.cancelTask(this, taskId))
            }

            "startForegroundService" -> {
                maybeRequestNotificationPermission()
                AgentForegroundService.start(this)
                result.success(true)
            }

            "stopForegroundService" -> {
                AgentForegroundService.stop(this)
                result.success(true)
            }

            "isForegroundServiceRunning" ->
                result.success(AgentForegroundService.isRunning)

            "isExactAlarmAllowed" ->
                result.success(ScheduleManager.isExactAlarmAllowed(this))

            "requestExactAlarmPermission" -> {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    try {
                        startActivity(
                            Intent(
                                Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM,
                                Uri.parse("package:$packageName")
                            )
                        )
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("OPEN_SETTINGS_FAILED", e.message, null)
                    }
                } else {
                    // غير مطلوبة قبل أندرويد 12
                    result.success(true)
                }
            }

            else -> result.notImplemented()
        }
    }

    /**
     * طلب صلاحية الإشعارات — مطلوبة من أندرويد 13+
     * لعرض إشعار الخدمة الأمامية.
     */
    private fun maybeRequestNotificationPermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 2001)
        }
    }
}
