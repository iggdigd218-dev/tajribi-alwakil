package com.example.app.automation

import android.content.Context
import android.content.SharedPreferences
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * جسر الإعدادات المحلية: مفتاح الذكاء الاصطناعي + المزود + الموديل + الـ endpoint.
 * القناة: "com.example.app/settings"
 */
object AppSettingsBridge : MethodChannel.MethodCallHandler {

    const val CHANNEL = "com.example.app/settings"

    private const val PREFS_NAME = "app_settings"
    private const val KEY_API = "gemini_api_key"
    private const val KEY_PROVIDER = "ai_provider"
    private const val KEY_ENDPOINT = "ai_endpoint"
    private const val KEY_MODEL = "ai_model"
    private const val KEY_VOICE_PROFILE = "voice_profile"

    private var prefs: SharedPreferences? = null

    @JvmStatic
    fun register(context: Context, messenger: BinaryMessenger) {
        prefs = context.applicationContext
            .getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        MethodChannel(messenger, CHANNEL).setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {

            "getGeminiApiKey" ->
                result.success(prefs?.getString(KEY_API, "") ?: "")

            "setGeminiApiKey" -> {
                val key = call.argument<String>("key")
                if (key.isNullOrBlank()) {
                    result.error("INVALID_ARGUMENTS", "الوسيط 'key' مطلوب", null)
                } else {
                    prefs?.edit()?.putString(KEY_API, key.trim())?.apply()
                    result.success(true)
                }
            }

            "clearGeminiApiKey" -> {
                prefs?.edit()?.remove(KEY_API)?.apply()
                result.success(true)
            }

            "getVoiceProfile" ->
                result.success(prefs?.getString(KEY_VOICE_PROFILE, "calm") ?: "calm")

            "setVoiceProfile" -> {
                val id = call.argument<String>("id")
                if (id.isNullOrBlank()) {
                    result.error("INVALID_ARGUMENTS", "الوسيط 'id' مطلوب", null)
                } else {
                    prefs?.edit()?.putString(KEY_VOICE_PROFILE, id.trim())?.apply()
                    result.success(true)
                }
            }

            "getAiSettings" -> result.success(
                mapOf(
                    "provider" to (prefs?.getString(KEY_PROVIDER, "groq") ?: "groq"),
                    "endpoint" to (prefs?.getString(KEY_ENDPOINT, "") ?: ""),
                    "model" to (prefs?.getString(KEY_MODEL, "") ?: ""),
                    "apiKey" to (prefs?.getString(KEY_API, "") ?: "")
                )
            )

            "setAiSettings" -> {
                val key = call.argument<String>("apiKey")
                if (key.isNullOrBlank()) {
                    result.error("INVALID_ARGUMENTS", "الوسيط 'apiKey' مطلوب", null)
                    return
                }
                prefs?.edit()
                    ?.putString(KEY_API, key.trim())
                    ?.putString(
                        KEY_PROVIDER,
                        (call.argument<String>("provider") ?: "groq").trim()
                    )
                    ?.putString(
                        KEY_ENDPOINT,
                        (call.argument<String>("endpoint") ?: "").trim()
                    )
                    ?.putString(
                        KEY_MODEL,
                        (call.argument<String>("model") ?: "").trim()
                    )
                    ?.apply()
                result.success(true)
            }

            else -> result.notImplemented()
        }
    }
}
