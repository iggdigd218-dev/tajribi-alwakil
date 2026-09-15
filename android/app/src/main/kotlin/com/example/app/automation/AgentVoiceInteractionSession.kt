package com.example.app.automation

import android.content.Context
import android.os.Bundle
import android.service.voice.VoiceInteractionSession
import android.view.LayoutInflater
import android.widget.Button
import android.widget.TextView
import com.example.app.R

/**
 * جلسة المساعد الظاهرة فوق التطبيقات / شاشة القفل عند استدعاء الوكيل
 * من النظام (المساعد الافتراضي).
 */
class AgentVoiceInteractionSession(context: Context) : VoiceInteractionSession(context) {

    override fun onCreate() {
        super.onCreate()
        VoiceManager.init(context.applicationContext, null)
    }

    override fun onShow(args: Bundle?, showFlags: Int) {
        super.onShow(args, showFlags)

        val view = LayoutInflater.from(context).inflate(R.layout.voice_session, null)
        val hint = view.findViewById<TextView>(R.id.session_hint)
        hint.text = "نادِني بـ «${VoiceManager.getWakeWord()}» ثم قل أمرك"
        view.findViewById<Button>(R.id.session_close).setOnClickListener { hide() }
        setContentView(view)

        if (!AgentForegroundService.isRunning) {
            AgentForegroundService.start(context.applicationContext)
        }
        VoiceManager.startListening()
        FloatingOverlayManager.showIfPossible(context.applicationContext)
        FloatingOverlayManager.setListening(true)
    }
}
