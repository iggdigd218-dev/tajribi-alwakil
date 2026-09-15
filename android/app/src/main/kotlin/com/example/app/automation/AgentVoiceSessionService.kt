package com.example.app.automation

import android.os.Bundle
import android.service.voice.VoiceInteractionSession
import android.service.voice.VoiceInteractionSessionService

/**
 * مصنع جلسات المساعد — يستدعيه النظام عند تفعيل إيماءة المساعد.
 */
class AgentVoiceSessionService : VoiceInteractionSessionService() {

    override fun onNewSession(args: Bundle?): VoiceInteractionSession {
        return AgentVoiceInteractionSession(this)
    }
}
