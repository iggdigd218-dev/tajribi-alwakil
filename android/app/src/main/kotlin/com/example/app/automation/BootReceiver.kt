package com.example.app.automation

import android.Manifest
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.util.Log

/**
 * يستأنف الاستماع الدائم بعد إقلاع الجهاز مباشرة — فيستجيب الوكيل
 * لكلمة النداء في الخلفية والشاشة مقفلة كما يفعل المساعدون الرسميون.
 * يعمل تحت مظلة AgentForegroundService (نوع microphone) مع WakeLock.
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED) return
        if (context.checkSelfPermission(Manifest.permission.RECORD_AUDIO) !=
            PackageManager.PERMISSION_GRANTED
        ) return
        Log.i("BootReceiver", "الإقلاع اكتمل — تشغيل خدمة الاستماع الدائم")
        AgentForegroundService.start(context)
        VoiceManager.init(context, null)
        VoiceManager.startListening()
    }
}
