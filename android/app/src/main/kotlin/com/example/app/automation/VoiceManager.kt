package com.example.app.automation

import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.util.Log
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.Locale

/**
 * محرك الصوت الأصلي (المرحلة 5): استماع دائم + كشف اسم النداء + نطق رجالي.
 *
 * ── الاستماع (STT):
 *  - حلقة استماع دائمة عبر SpeechRecognizer تعمل والشاشة مغلقة،
 *    تحت مظلة AgentForegroundService (نوع microphone) مع WakeLock.
 *  - كشف اسم النداء المخصص (Wake-Word): إذا بدأ الكلام باسم الوكيل
 *    يُقتطع ويُمرر الباقي كأمر إلى Dart عبر onWakeWordTriggered،
 *    وإلا يُتجاهل الكلام بصمت وتُعاد فتح جلسة الاستماع فوراً.
 *  - إعادة فتح تلقائية للميكروفون عند onEndOfSpeech / onError مع
 *    تراجع أُسّي (backoff) يمنع حلقات الانشغال.
 *
 * ── النطق (TTS):
 *  - صوت عربي بنبرة رجالية: فلترة أصوات النظام بحثاً عن صوت موسوم
 *    بـ "male"، مع خفض النبرة setPitch(0.88f) وسرعة طبيعية 1.0f.
 *  - إسكات الميكروفون مؤقتاً أثناء النطق حتى لا يسمع الوكيل صوته،
 *    ثم استئناف الاستماع تلقائياً عند انتهاء الكلام.
 */
object VoiceManager : RecognitionListener {

    private const val TAG = "VoiceManager"

    private const val PREFS_NAME = "agent_voice_prefs"
    private const val KEY_WAKE_WORD = "wake_word"
    private const val DEFAULT_WAKE_WORD = "حمود"

    private const val UTTERANCE_ID = "agent_voice_reply"

    /** تأخير إعادة فتح الميكروفون بعد كل جلسة (ميلي ثانية). */
    private const val RESTART_DELAY_MS = 250L

    /** تراجع أُسّي عند الأخطاء المتتالية: 300 → 600 → ... → 5000 كحد أقصى. */
    private const val BASE_BACKOFF_MS = 300L
    private const val MAX_BACKOFF_MS = 5000L

    // ═══════════════════════════════════════════
    //  الحالة العامة
    // ═══════════════════════════════════════════

    private var appContext: Context? = null

    /** القناة نحو Dart — تُستخدم لتمرير الأوامر الملتقطة والأحداث. */
    private var channel: MethodChannel? = null

    private var prefs: SharedPreferences? = null
    private var initialized = false

    /** اسم النداء الحي (يُحمَّل من التفضيلات ويُحدَّث عبر setWakeWord). */
    @Volatile
    private var wakeWord: String = DEFAULT_WAKE_WORD

    // ═══════════════════════════════════════════
    //  حالة النطق (TTS)
    // ═══════════════════════════════════════════

    private var tts: TextToSpeech? = null

    @Volatile
    private var ttsReady = false

    /** نص مؤجل يُنطق فور جاهزية المحرك. */
    @Volatile
    private var pendingSpeak: String? = null

    // ═══════════════════════════════════════════
    //  حالة الاستماع (STT)
    // ═══════════════════════════════════════════

    @Volatile
    private var continuousMode = false

    /** true أثناء نطق الوكيل — الميكروفون موقوف مؤقتاً. */
    @Volatile
    private var pauseMicForTts = false

    private var recognizer: SpeechRecognizer? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var consecutiveErrors = 0
    private const val KEY_LISTENING_ON = "listening_on"

    /** مستقبل تشغيل الشاشة: بعض الواجهات تجمّد الميكروفون والشاشة مطفأة —
     *  نعيد فتح الجلسة فوراً عند التشغيل لن يبقى النداء حياً. */
    private val screenReceiver = object : android.content.BroadcastReceiver() {
        override fun onReceive(context: android.content.Context?, intent: android.content.Intent?) {
            if (intent?.action != android.content.Intent.ACTION_SCREEN_ON) return
            if (!continuousMode) return
            Log.i(TAG, "الشاشة تعمل — إنعاش جلسة الاستماع")
            mainHandler.post {
                try {
                    destroyRecognizer()
                    startRecognitionSession()
                } catch (e: Exception) {
                    scheduleRestart(nextBackoff())
                }
            }
        }
    }
    private var screenReceiverRegistered = false

    private val mainHandler = Handler(Looper.getMainLooper())

    /**
     * مهمة إعادة فتح جلسة الاستماع — مهمة واحدة مجدولة دائماً
     * (removeCallbacks قبل أي جدولة جديدة) لمنع التكرار.
     */
    private val restartRunnable = Runnable {
        if (!continuousMode) return@Runnable
        try {
            startRecognitionSession()
        } catch (e: Exception) {
            Log.e(TAG, "فشل فتح جلسة استماع: ${e.message}")
            scheduleRestart(nextBackoff())
        }
    }

    // ═══════════════════════════════════════════
    //  التهيئة (من MainActivity)
    // ═══════════════════════════════════════════

    /**
     * تهيئة المحرك — تُستدعى من configureFlutterEngine().
     * عند إعادة إنشاء محرك Flutter تُحدَّث القناة فقط دون إعادة
     * بناء المحرك (TTS والاستماع يستمران).
     */
    /** أوامر النداء التي وصلت قبل ارتباط قناة Flutter. */
    private val pendingWakeCommands = ArrayDeque<String>(8)

    @JvmStatic
    fun init(context: Context, voiceChannel: MethodChannel?) {
        appContext = context.applicationContext
        channel = voiceChannel
        if (voiceChannel != null) {
            flushPendingWakeCommands()
        }
        if (initialized) return
        initialized = true

        prefs = appContext?.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        wakeWord = prefs?.getString(KEY_WAKE_WORD, DEFAULT_WAKE_WORD) ?: DEFAULT_WAKE_WORD

        initTts()
        Log.i(TAG, "تهيئة محرك الصوت — اسم النداء الحالي: \"$wakeWord\"")
    }

    // ═══════════════════════════════════════════
    //  اسم النداء (Wake-Word)
    // ═══════════════════════════════════════════

    /** حفظ اسم الوكيل في التفضيلات وتحديث المتغير الحي. */
    @JvmStatic
    fun setWakeWord(name: String) {
        val clean = name.trim()
        if (clean.isEmpty()) return
        wakeWord = clean
        prefs?.edit()?.putString(KEY_WAKE_WORD, clean)?.apply()
        Log.i(TAG, "✔ تم تحديث اسم النداء إلى: \"$clean\"")
    }

    @JvmStatic
    fun getWakeWord(): String = wakeWord

    // ═══════════════════════════════════════════
    //  التحكم بالاستماع الدائم
    // ═══════════════════════════════════════════

    /**
     * بدء حلقة الاستماع الدائم — يعمل والشاشة مغلقة تحت مظلة
     * AgentForegroundService (تُشغَّل تلقائياً إن لم تكن تعمل)
     * مع PARTIAL_WAKE_LOCK لبقاء المعالج والميكروفون نشطين.
     */
    @JvmStatic
    fun startListening(): Boolean {
        val context = appContext ?: return false
        if (continuousMode) return true

        if (!hasRecordAudio(context)) {
            Log.e(TAG, "صلاحية الميكروفون غير ممنوحة — يُرفض بدء الاستماع")
            return false
        }

        continuousMode = true
        consecutiveErrors = 0

        // المظلة: الخدمة الأمامية (بنوع microphone) تسمح بالاستماع
        // في الخلفية من أندرويد 11+ وتحمي العملية من القتل.
        if (!AgentForegroundService.isRunning) {
            AgentForegroundService.start(context)
        }

        acquireWakeLock()
        prefs?.edit()?.putBoolean(KEY_LISTENING_ON, true)?.apply()
        if (!screenReceiverRegistered) {
            try {
                context.registerReceiver(
                    screenReceiver,
                    android.content.IntentFilter(android.content.Intent.ACTION_SCREEN_ON),
                )
                screenReceiverRegistered = true
            } catch (e: Exception) {
                Log.w(TAG, "تعذر تسجيل مستقبل الشاشة: ${e.message}")
            }
        }
        notifyListeningState(true)
        FloatingOverlayManager.showIfPossible(context)
        FloatingOverlayManager.setListening(true)
        Log.i(TAG, "▶ بدأ الاستماع الدائم — نادِ الوكيل بـ \"$wakeWord\"")

        mainHandler.post {
            try {
                startRecognitionSession()
            } catch (e: Exception) {
                Log.e(TAG, "تعذر بدء جلسة الاستماع: ${e.message}")
                scheduleRestart(nextBackoff())
            }
        }
        return true
    }

    /** إيقاف حلقة الاستماع الدائم وتحرير كل الموارد. */
    @JvmStatic
    fun stopListening() {
        if (!continuousMode) return
        continuousMode = false
        prefs?.edit()?.putBoolean(KEY_LISTENING_ON, false)?.apply()
        if (screenReceiverRegistered) {
            try {
                appContext?.unregisterReceiver(screenReceiver)
            } catch (_: Exception) {
            }
            screenReceiverRegistered = false
        }
        pauseMicForTts = false
        mainHandler.removeCallbacks(restartRunnable)
        destroyRecognizer()
        releaseWakeLock()
        notifyListeningState(false)
        FloatingOverlayManager.setListening(false)
        Log.i(TAG, "■ توقف الاستماع الدائم")
    }

    @JvmStatic
    fun isListening(): Boolean = continuousMode

    /** يستأنف الاستماع إن كان مفعلاً قبل أن يقتل النظام العملية —
     *  تستدعيه الخدمة الأمامية عند إعادة تشغيلها اللزج (START_STICKY). */
    @JvmStatic
    fun resumeIfWasListening() {
        val context = appContext ?: return
        val on = prefs?.getBoolean(KEY_LISTENING_ON, false) ?: false
        if (!on || continuousMode) return
        if (!hasRecordAudio(context)) return
        Log.i(TAG, "استئناف تلقائي للاستماع الدائم بعد إعادة تشغيل الخدمة")
        startListening()
    }

    // ═══════════════════════════════════════════
    //  النطق (TTS رجالي)
    // ═══════════════════════════════════════════

    /**
     * نطق نص بصوت عربي رجالي وقور.
     * يُسكِت الميكروفون مؤقتاً أثناء النطق ثم يستأنفه تلقائياً.
     */
    @JvmStatic
    fun speak(text: String) {
        if (text.isBlank()) return
        val engine = tts ?: return
        if (!ttsReady) {
            pendingSpeak = text // سيُنطق فور جاهزية المحرك
            return
        }

        // أوقف الميكروفون حتى لا يسمع الوكيل صوته فيستجيب لنفسه
        if (continuousMode) {
            pauseMicForTts = true
            mainHandler.removeCallbacks(restartRunnable)
            try {
                recognizer?.cancel()
            } catch (_: Exception) {
            }
        }

        try {
            engine.setPitch(0.88f)   // نبرة أخفض = صوت ذكوري وقور
            engine.setSpeechRate(1.0f)
            engine.speak(text, TextToSpeech.QUEUE_FLUSH, null, UTTERANCE_ID)
        } catch (e: Exception) {
            Log.e(TAG, "فشل النطق: ${e.message}")
            resumeMicAfterSpeech()
        }
    }

    // ══════════════════════════════════════════════════════════
    //  الصوت العصبي: تشغيل ملفات MP3 المولّدة عبر Edge TTS
    // ══════════════════════════════════════════════════════════
    private var mediaPlayer: MediaPlayer? = null
    private val audioQueue = ArrayDeque<String>()
    private var audioChainActive = false

    /**
     * صف ملفاً صوتياً للتشغيل (MP3 عصبي من Edge TTS).
     * يعيد false إن كان الملف غير صالح — ليتراجع Dart لمحرك النظام.
     */
    @JvmStatic
    fun playAudioFile(path: String): Boolean {
        val f = File(path)
        if (!f.exists() || f.length() < 512L) return false
        audioQueue.addLast(path)
        if (!audioChainActive) startNextAudio()
        return true
    }

    private fun startNextAudio() {
        // removeFirst() بعد فحص الفراغ: pollFirst() غير موجودة في
        // kotlin.collections.ArrayDeque بإصدار Kotlin هنا (أضيفت في 2.1)،
        // والنوع الصريح String يمنع أي لبس في أحمال setDataSource الزائدة.
        if (audioQueue.isEmpty()) {
            audioChainActive = false
            resumeMicAfterSpeech() // نفس سلوك انتهاء TTS — استئناف الميكروفون
            return
        }
        val next: String = audioQueue.removeFirst()
        audioChainActive = true

        // أسكِت الميكروفون حتى لا يسمع الوكيل نفسه
        if (continuousMode) {
            pauseMicForTts = true
            mainHandler.removeCallbacks(restartRunnable)
            try {
                recognizer?.cancel()
            } catch (_: Exception) {
            }
        }

        try {
            try {
                tts?.stop() // صوت النظام يتنازل للصوت العصبي
            } catch (_: Exception) {
            }
            releasePlayer()
            val mp = MediaPlayer()
            mediaPlayer = mp
            mp.setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_ASSISTANT)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build()
            )
            mp.setDataSource(next)
            mp.setOnCompletionListener {
                releasePlayer()
                startNextAudio()
            }
            mp.setOnErrorListener { _, _, _ ->
                releasePlayer()
                startNextAudio()
                true
            }
            mp.prepare()
            mp.start()
            // حذف الملف المؤقت بعد بدء التشغيل الآمن
            try {
                File(next).delete()
            } catch (_: Exception) {
            }
        } catch (e: Exception) {
            Log.e(TAG, "فشل تشغيل الصوت العصبي: ${e.message}")
            releasePlayer()
            startNextAudio() // تخطَّ المعطوب للتالي
        }
    }

    private fun releasePlayer() {
        try {
            mediaPlayer?.release()
        } catch (_: Exception) {
        }
        mediaPlayer = null
    }

    /** إيقاف الصوت العصبي فوراً وتفريغ الطابور (+ إسكات TTS). */
    @JvmStatic
    fun stopAudioPlayback() {
        audioQueue.clear()
        audioChainActive = false
        releasePlayer()
        try {
            tts?.stop()
        } catch (_: Exception) {
        }
        resumeMicAfterSpeech()
    }

    @JvmStatic
    fun isAudioPlaying(): Boolean = audioChainActive

    private fun initTts() {
        val context = appContext ?: return
        tts = TextToSpeech(context) { status ->
            // قد يصل الرد من خيط غير رئيسي — ننقله للخيط الرئيسي
            mainHandler.post {
                if (status == TextToSpeech.SUCCESS) {
                    configureMaleVoice()
                    installUtteranceListener()
                    ttsReady = true
                    Log.i(TAG, "محرك النطق جاهز ✅")
                    pendingSpeak?.let { text ->
                        pendingSpeak = null
                        speak(text)
                    }
                } else {
                    Log.e(TAG, "فشل تهيئة محرك النطق (code=$status)")
                    notifyVoiceError("فشل تهيئة محرك النطق — تأكد من تثبيت محرك TTS يدعم العربية")
                }
            }
        }
    }

    /**
     * تخصيص الصوت الرجالي العربي:
     *  1. ضبط اللغة العربية.
     *  2. استعراض أصوات النظام وفلترة صوت باسم يحتوي "male".
     *  3. احتياطي: أول صوت عربي غير موسوم بـ "female".
     *  4. خفض النبرة 0.88 وسرعة 1.0 لإنتاج نبرة ذكورية واضحة حتى
     *     مع المحركات التي لا توسم الأصوات بالجنس.
     */
    private fun configureMaleVoice() {
        val engine = tts ?: return

        try {
            val result = engine.setLanguage(Locale("ar"))
            if (result == TextToSpeech.LANG_MISSING_DATA ||
                result == TextToSpeech.LANG_NOT_SUPPORTED
            ) {
                Log.w(TAG, "بيانات الصوت العربي غير متوفرة في محرك النطق — جرّب تثبيت/تحديث صوت Google")
            }
        } catch (e: Exception) {
            Log.e(TAG, "setLanguage فشل: ${e.message}")
        }

        try {
            val arabicVoices = engine.voices.orEmpty()
                .filter { it.locale.language.equals("ar", ignoreCase = true) }

            val maleVoice = arabicVoices.firstOrNull { voice ->
                voice.name.contains("male", ignoreCase = true)
            } ?: arabicVoices.firstOrNull { voice ->
                !voice.name.contains("female", ignoreCase = true)
            }

            if (maleVoice != null) {
                engine.voice = maleVoice
                Log.i(TAG, "تم اختيار الصوت الرجالي: ${maleVoice.name}")
            } else {
                Log.i(TAG, "لا يوجد صوت عربي موسوم بذكر — الاعتماد على نبرة 0.88")
            }
        } catch (e: Exception) {
            Log.e(TAG, "فلترة الأصوات فشلت: ${e.message}")
        }

        // النبرة والسرعة المطلوبتان
        engine.setPitch(0.88f)
        engine.setSpeechRate(1.0f)
    }

    /** استئناف الميكروفون بعد انتهاء النطق (من خيط النطق). */
    private fun installUtteranceListener() {
        val engine = tts ?: return
        engine.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
            override fun onStart(utteranceId: String?) { /* لا شيء */ }

            override fun onDone(utteranceId: String?) {
                resumeMicAfterSpeech()
            }

            @Deprecated("Deprecated in Java")
            override fun onError(utteranceId: String?) {
                resumeMicAfterSpeech()
            }

            override fun onError(utteranceId: String?, errorCode: Int) {
                resumeMicAfterSpeech()
            }
        })
    }

    private fun resumeMicAfterSpeech() {
        mainHandler.post {
            if (pauseMicForTts) {
                pauseMicForTts = false
                if (continuousMode) startRecognitionSession()
            }
        }
    }

    // ═══════════════════════════════════════════
    //  إدارة جلسات التعرف على الكلام
    // ═══════════════════════════════════════════

    /**
     * إنشاء متعرف جديد — يفضل محرك التعرف على الجهاز (On-Device،
     * يعمل دون إنترنت) عندما يكون متاحاً، وإلا محرك الخدمة القياسي.
     */
    private fun createRecognizer(): SpeechRecognizer {
        val context = appContext ?: throw IllegalStateException("VoiceManager غير مهيأ")
        val newRecognizer =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
                SpeechRecognizer.isOnDeviceRecognitionAvailable(context)
            ) {
                SpeechRecognizer.createOnDeviceSpeechRecognizer(context)
            } else {
                SpeechRecognizer.createSpeechRecognizer(context)
            }
        newRecognizer.setRecognitionListener(this)
        return newRecognizer
    }

    private fun recognitionIntent(): Intent =
        Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(
                RecognizerIntent.EXTRA_LANGUAGE_MODEL,
                RecognizerIntent.LANGUAGE_MODEL_FREE_FORM
            )
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, "ar")
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_PREFERENCE, "ar")
            putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 3)
            appContext?.let { putExtra(RecognizerIntent.EXTRA_CALLING_PACKAGE, it.packageName) }
        }

    private fun startRecognitionSession() {
        if (!continuousMode) return
        val current = recognizer ?: createRecognizer().also { recognizer = it }
        try {
            current.startListening(recognitionIntent())
        } catch (e: Exception) {
            Log.e(TAG, "startListening فشل: ${e.message}")
            destroyRecognizer()
            scheduleRestart(nextBackoff())
        }
    }

    private fun destroyRecognizer() {
        try {
            recognizer?.destroy()
        } catch (_: Exception) {
        }
        recognizer = null
    }

    /** جدولة إعادة فتح الميكروفون (مهمة واحدة فقط في كل لحظة). */
    private fun scheduleRestart(delayMs: Long) {
        mainHandler.removeCallbacks(restartRunnable)
        if (!continuousMode) return
        mainHandler.postDelayed(restartRunnable, delayMs)
    }

    private fun nextBackoff(): Long {
        val delay = BASE_BACKOFF_MS * (1L shl consecutiveErrors.coerceAtMost(4))
        return delay.coerceAtMost(MAX_BACKOFF_MS)
    }

    // ═══════════════════════════════════════════
    //  RecognitionListener — قلب حلقة الاستماع
    // ═══════════════════════════════════════════

    override fun onReadyForSpeech(params: Bundle?) {
        consecutiveErrors = 0
    }

    override fun onBeginningOfSpeech() { /* الميكروفون يلتقط كلاماً */ }

    override fun onRmsChanged(rmsdB: Float) { /* مستوى الصوت — غير مستخدم */ }

    override fun onBufferReceived(buffer: ByteArray?) { /* غير مستخدم */ }

    override fun onEndOfSpeech() {
        // انتهى الكلام — يصل onResults عادة بعدها؛ نجددول احتياطياً
        // تحسباً للمحركات التي لا ترسل النتائج بعد صمت طويل.
        scheduleRestart(RESTART_DELAY_MS + 400)
    }

    override fun onError(error: Int) {
        val description = when (error) {
            SpeechRecognizer.ERROR_AUDIO -> "خطأ صوتي"
            SpeechRecognizer.ERROR_CLIENT -> "خطأ عميل"
            SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> "صلاحيات غير كافية"
            SpeechRecognizer.ERROR_NETWORK -> "خطأ شبكة"
            SpeechRecognizer.ERROR_NETWORK_TIMEOUT -> "انتهت مهلة الشبكة"
            SpeechRecognizer.ERROR_NO_MATCH -> "لا تطابق"
            SpeechRecognizer.ERROR_RECOGNIZER_BUSY -> "المتعرف مشغول"
            SpeechRecognizer.ERROR_SERVER -> "خطأ خادم"
            SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> "انتهت مهلة الكلام"
            else -> "خطأ غير معروف ($error)"
        }
        Log.w(TAG, "onError: $description")

        if (error == SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS) {
            notifyVoiceError("صلاحية الميكروفون سُحبت — تم إيقاف الاستماع")
            mainHandler.post { stopListening() }
            return
        }

        consecutiveErrors++
        // إعادة بناء نظيفة تتفادى stuck على RECOGNIZER_BUSY
        destroyRecognizer()
        scheduleRestart(nextBackoff())
    }

    override fun onResults(results: Bundle?) {
        consecutiveErrors = 0

        val spoken = extractBestText(results)
        if (spoken.isNullOrBlank()) {
            scheduleRestart(RESTART_DELAY_MS)
            return
        }
        Log.d(TAG, "سُمع: \"$spoken\"")

        // ── كشف اسم النداء على النص المُطبَّع ──
        val normalized = normalizeArabic(spoken)
        val normalizedWake = normalizeArabic(wakeWord)

        val command: String? = when {
            normalized.startsWith(normalizedWake) ->
                normalized.substring(normalizedWake.length).trim()
            normalized.contains(normalizedWake) ->
                normalized.substringAfter(normalizedWake).trim()
            else -> null
        }

        if (!command.isNullOrBlank()) {
            Log.i(TAG, "🎙️ اسم النداء مكتشف — الأمر: \"$command\"")
            FloatingOverlayManager.setStatus("🎙️ $command")
            invokeDart("onWakeWordTriggered", command)
        } else if (normalized.contains(normalizedWake)) {
            Log.i(TAG, "نودي باسم الوكيل دون أمر — تجاهل بهدوء")
        } else {
            Log.d(TAG, "كلام بدون اسم النداء — تجاهل صامت وإعادة فتح الميكروفون")
        }

        // في كل الحالات: إعادة فتح الميكروفون بصمت
        scheduleRestart(RESTART_DELAY_MS)
    }

    override fun onPartialResults(partialResults: Bundle?) {
        // نعتمد النتائج النهائية فقط لتفادي التنفيذ المبكر
    }

    override fun onEvent(eventType: Int, params: Bundle?) { /* غير مستخدم */ }

    // ═══════════════════════════════════════════
    //  WakeLock — بقاء الميكروفون مع الشاشة المغلقة
    // ═══════════════════════════════════════════

    @SuppressLint("WakelockTimeout")
    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) return
        val context = appContext ?: return
        val powerManager = context.getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = powerManager.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK,
            "agent_automation:voice"
        ).apply {
            setReferenceCounted(false)
            // بلا مهلة: مطلوب طالما الاستماع الدائم مفعّل
            // (يُحرَّر فوراً في stopListening — لا تسريب)
            acquire()
        }
    }

    private fun releaseWakeLock() {
        try {
            if (wakeLock?.isHeld == true) wakeLock?.release()
        } catch (_: Exception) {
        }
        wakeLock = null
    }

    // ═══════════════════════════════════════════
    //  أدوات مساعدة
    // ═══════════════════════════════════════════

    private fun hasRecordAudio(context: Context): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            context.checkSelfPermission(android.Manifest.permission.RECORD_AUDIO) ==
                android.content.pm.PackageManager.PERMISSION_GRANTED
        } else {
            true
        }
    }

    /** أفضل نص من نتائج التعرف. */
    private fun extractBestText(results: Bundle?): String? {
        if (results == null) return null
        val list = results.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
            ?: return null
        return list.firstOrNull { !it.isNullOrBlank() }
    }

    /**
     * تطبيع النص العربي للمقارنة الموثوقة مع اسم النداء:
     * أرقام شرقية → غربية، توحيد الهمزات والتاء المربوطة،
     * إزالة التشكيل والتطويل، ضغط الفراغات.
     */
    private fun normalizeArabic(input: String): String {
        var t = input.trim()
        // ⚠️ const غير مسموحة داخل الدوال — val عادية تكفي هنا
        val easternDigits = "٠١٢٣٤٥٦٧٨٩"
        val persianDigits = "۰۱۲۳۴۵۶۷۸۹"
        for (i in 0..9) {
            t = t.replace(easternDigits[i], '0' + i)
                .replace(persianDigits[i], '0' + i)
        }
        t = t.replace("أ", "ا")
            .replace("إ", "ا")
            .replace("آ", "ا")
            .replace("ة", "ه")
        t = t.replace(Regex("[\\u064B-\\u0652\\u0670\\u0640]"), "")
        t = t.replace(Regex("\\s+"), " ")
        return t.trim()
    }

    /** استدعاء Dart عبر القناة — دائماً على الخيط الرئيسي. */
    private fun invokeDart(method: String, argument: Any?) {
        mainHandler.post {
            if (method == "onWakeWordTriggered" && argument is String && channel == null) {
                enqueueWakeCommand(argument)
                bringAppToForeground(argument)
                return@post
            }
            try {
                channel?.invokeMethod(method, argument)
            } catch (e: Exception) {
                Log.e(TAG, "تعذر استدعاء Dart ($method): ${e.message}")
            }
        }
    }

    private fun enqueueWakeCommand(command: String) {
        if (pendingWakeCommands.size >= 8) pendingWakeCommands.removeFirst()
        pendingWakeCommands.addLast(command)
    }

    private fun flushPendingWakeCommands() {
        val ch = channel ?: return
        while (pendingWakeCommands.isNotEmpty()) {
            val cmd = pendingWakeCommands.removeFirst()
            try {
                ch.invokeMethod("onWakeWordTriggered", cmd)
            } catch (e: Exception) {
                Log.e(TAG, "تعذر تفريغ أمر النداء: ${e.message}")
            }
        }
    }

    private fun bringAppToForeground(command: String) {
        val ctx = appContext ?: return
        val launch = ctx.packageManager.getLaunchIntentForPackage(ctx.packageName) ?: return
        launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        launch.putExtra("pending_voice_command", command)
        try {
            ctx.startActivity(launch)
        } catch (e: Exception) {
            Log.w(TAG, "تعذر رفع التطبيق لمعالجة الأمر الصوتي: ${e.message}")
        }
    }

    private fun notifyListeningState(active: Boolean) {
        invokeDart("onListeningStateChanged", active)
    }

    private fun notifyVoiceError(message: String) {
        invokeDart("onVoiceError", message)
    }
}
