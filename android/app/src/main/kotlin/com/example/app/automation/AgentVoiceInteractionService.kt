package com.example.app.automation

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.service.voice.VoiceInteractionService
import android.util.Log

/**
 * خدمة المساعد الصوتي الرسمية للنظام.
 *
 * بعد اختيار «وكيل الأتمتة» كتطبيق المساعد الافتراضي، يربط النظام هذه
 * الخدمة ويُطلق الجلسة عند إيماءة المساعد (ضغطة المطافئ / زر المنزل المطوّل).
 * عند الجاهزية نبدأ الاستماع الدائم ونظهر النافذة العائمة إن وُجدت الصلاحية.
 */
class AgentVoiceInteractionService : VoiceInteractionService() {

    companion object {
        private const val TAG = "AgentVoiceIxService"
    }

    override fun onReady() {
        super.onReady()
        Log.i(TAG, "VoiceInteractionService جاهزة — المساعد الافتراضي مفعّل")
        VoiceManager.init(applicationContext, null)

        if (!AgentForegroundService.isRunning) {
            AgentForegroundService.start(applicationContext)
        }

        if (FloatingOverlayManager.canDrawOverlays(this)) {
            FloatingOverlayManager.show(this)
        }

        if (hasRecordAudio()) {
            VoiceManager.startListening()
        }
    }

    override fun onShutdown() {
        Log.i(TAG, "VoiceInteractionService أُغلقت")
        super.onShutdown()
    }

    private fun hasRecordAudio(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            checkSelfPermission(Manifest.permission.RECORD_AUDIO) ==
                PackageManager.PERMISSION_GRANTED
        } else {
            true
        }
    }
}
