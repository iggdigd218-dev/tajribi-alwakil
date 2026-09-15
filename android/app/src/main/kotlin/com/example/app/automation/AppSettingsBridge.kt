package com.example.app.automation

import android.content.Context
import android.content.SharedPreferences
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * جسر الإعدادات المحلية (المرحلة 5b): حفظ مفتاح Gemini API
 * في SharedPreferences — دون أي حزم خارجية في pubspec.yaml.
 *
 * القناة: "com.example.app/settings"
 *  - getGeminiApiKey  → قراءة المفتاح المحفوظ ("" إن لم يوجد).
 *  - setGeminiApiKey  → حفظ المفتاح تحت "gemini_api_key".
 *  - clearGeminiApiKey → حذف المفتاح المخزن.
 */
object AppSettingsBridge : MethodChannel.MethodCallHandler {

    const val CHANNEL = "com.example.app/settings"

    private const val PREFS_NAME = "app_settings"
    private const val KEY_GEMINI_API = "gemini_api_key"

    private var prefs: SharedPreferences? = null

    /** التسجيل من configureFlutterEngine في MainActivity. */
    @JvmStatic
    fun register(context: Context, messenger: BinaryMessenger) {
        prefs = context.applicationContext
            .getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        MethodChannel(messenger, CHANNEL).setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {

            "getGeminiApiKey" ->
                result.success(prefs?.getString(KEY_GEMINI_API, "") ?: "")

            "setGeminiApiKey" -> {
                val key = call.argument<String>("key")
                if (key.isNullOrBlank()) {
                    result.error("INVALID_ARGUMENTS", "الوسيط 'key' مطلوب", null)
                } else {
                    prefs?.edit()?.putString(KEY_GEMINI_API, key.trim())?.apply()
                    result.success(true)
                }
            }

            "clearGeminiApiKey" -> {
                prefs?.edit()?.remove(KEY_GEMINI_API)?.apply()
                result.success(true)
            }

            else -> result.notImplemented()
        }
    }
}
