package com.example.app.automation

import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.speech.RecognitionListener
import android.speech.RecognitionService
import android.speech.SpeechRecognizer
import android.util.Log

/**
 * خدمة التعرف على الكلام التي يطلبها VoiceInteractionService.
 * تغلّف SpeechRecognizer الأصلي (On-Device إن توفر).
 */
class AgentRecognitionService : RecognitionService() {

    companion object {
        private const val TAG = "AgentRecognition"
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private var recognizer: SpeechRecognizer? = null

    override fun onStartListening(recognizerIntent: Intent, listener: Callback) {
        mainHandler.post {
            destroyRecognizer()
            val sr = createRecognizer()
            sr.setRecognitionListener(ListenerAdapter(listener))
            recognizer = sr
            try {
                sr.startListening(recognizerIntent)
            } catch (e: Exception) {
                Log.e(TAG, "startListening فشل: ${e.message}")
                try {
                    listener.error(SpeechRecognizer.ERROR_CLIENT)
                } catch (_: Exception) {
                }
            }
        }
    }

    override fun onCancel(listener: Callback) {
        mainHandler.post {
            try {
                recognizer?.cancel()
            } catch (_: Exception) {
            }
            destroyRecognizer()
        }
    }

    override fun onStopListening(listener: Callback) {
        mainHandler.post {
            try {
                recognizer?.stopListening()
            } catch (_: Exception) {
            }
        }
    }

    override fun onDestroy() {
        mainHandler.post { destroyRecognizer() }
        super.onDestroy()
    }

    private fun createRecognizer(): SpeechRecognizer {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
            SpeechRecognizer.isOnDeviceRecognitionAvailable(this)
        ) {
            SpeechRecognizer.createOnDeviceSpeechRecognizer(this)
        } else {
            SpeechRecognizer.createSpeechRecognizer(this)
        }
    }

    private fun destroyRecognizer() {
        try {
            recognizer?.destroy()
        } catch (_: Exception) {
        }
        recognizer = null
    }

    private class ListenerAdapter(
        private val callback: Callback
    ) : RecognitionListener {

        override fun onReadyForSpeech(params: Bundle?) {
            // لا مقابل مباشر — beginningOfSpeech عند بدء الكلام
        }

        override fun onBeginningOfSpeech() {
            try {
                callback.beginningOfSpeech()
            } catch (_: Exception) {
            }
        }

        override fun onRmsChanged(rmsdB: Float) {
            try {
                callback.rmsChanged(rmsdB)
            } catch (_: Exception) {
            }
        }

        override fun onBufferReceived(buffer: ByteArray?) {
            if (buffer == null) return
            try {
                callback.bufferReceived(buffer)
            } catch (_: Exception) {
            }
        }

        override fun onEndOfSpeech() {
            try {
                callback.endOfSpeech()
            } catch (_: Exception) {
            }
        }

        override fun onError(error: Int) {
            try {
                callback.error(error)
            } catch (_: Exception) {
            }
        }

        override fun onResults(results: Bundle?) {
            try {
                callback.results(results)
            } catch (_: Exception) {
            }
        }

        override fun onPartialResults(partialResults: Bundle?) {
            try {
                callback.partialResults(partialResults)
            } catch (_: Exception) {
            }
        }

        override fun onEvent(eventType: Int, params: Bundle?) { /* غير مستخدم */ }
    }
}
