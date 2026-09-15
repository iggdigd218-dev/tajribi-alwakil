package com.example.app.automation

import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.graphics.PixelFormat
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import android.view.Gravity
import android.view.LayoutInflater
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.widget.ImageView
import android.widget.TextView
import com.example.app.R

/**
 * النافذة العائمة الدائمة فوق كل التطبيقات.
 *
 * تتطلب صلاحية SYSTEM_ALERT_WINDOW (تُمنح من إعدادات النظام).
 * تُظهر حالة الاستماع وآخر أمر، وتُسحب بالإصبع.
 */
object FloatingOverlayManager {

    private const val TAG = "FloatingOverlay"

    private val mainHandler = Handler(Looper.getMainLooper())

    private var windowManager: WindowManager? = null
    private var overlayView: View? = null
    private var layoutParams: WindowManager.LayoutParams? = null
    private var statusView: TextView? = null
    private var micView: ImageView? = null

    @Volatile
    private var showing = false

    @Volatile
    private var listening = false

    @Volatile
    private var statusText: String = "وكيل"

    fun canDrawOverlays(context: Context): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            Settings.canDrawOverlays(context)
        } else {
            true
        }
    }

    fun isShowing(): Boolean = showing

    fun showIfPossible(context: Context) {
        if (canDrawOverlays(context)) show(context)
    }

    @JvmStatic
    fun show(context: Context) {
        val app = context.applicationContext
        mainHandler.post {
            if (showing && overlayView != null) {
                applyVisualState()
                return@post
            }
            if (!canDrawOverlays(app)) {
                Log.w(TAG, "صلاحية النافذة العائمة غير ممنوحة")
                return@post
            }
            try {
                attach(app)
            } catch (e: Exception) {
                Log.e(TAG, "تعذر إظهار النافذة العائمة: ${e.message}")
                showing = false
            }
        }
    }

    @JvmStatic
    fun hide() {
        mainHandler.post {
            detach()
        }
    }

    @JvmStatic
    fun setListening(active: Boolean) {
        listening = active
        statusText = if (active) "الاستماع نشط" else "وكيل"
        mainHandler.post { applyVisualState() }
    }

    @JvmStatic
    fun setStatus(text: String) {
        if (text.isBlank()) return
        statusText = text
        mainHandler.post { applyVisualState() }
    }

    @SuppressLint("InflateParams", "ClickableViewAccessibility")
    private fun attach(context: Context) {
        detach()

        val wm = context.getSystemService(Context.WINDOW_SERVICE) as WindowManager
        val view = LayoutInflater.from(context).inflate(R.layout.floating_overlay, null)
        val status = view.findViewById<TextView>(R.id.overlay_status)
        val mic = view.findViewById<ImageView>(R.id.overlay_mic)
        val close = view.findViewById<ImageView>(R.id.overlay_close)
        val card = view.findViewById<View>(R.id.overlay_card)

        val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        } else {
            @Suppress("DEPRECATION")
            WindowManager.LayoutParams.TYPE_PHONE
        }

        val params = WindowManager.LayoutParams(
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.WRAP_CONTENT,
            type,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
                WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL,
            PixelFormat.TRANSLUCENT
        ).apply {
            gravity = Gravity.TOP or Gravity.END
            x = 16
            y = 180
        }

        var lastX = 0
        var lastY = 0
        var startTouchX = 0f
        var startTouchY = 0f
        var dragged = false

        card.setOnTouchListener { _, event ->
            when (event.action) {
                MotionEvent.ACTION_DOWN -> {
                    lastX = params.x
                    lastY = params.y
                    startTouchX = event.rawX
                    startTouchY = event.rawY
                    dragged = false
                    true
                }
                MotionEvent.ACTION_MOVE -> {
                    val dx = (event.rawX - startTouchX).toInt()
                    val dy = (event.rawY - startTouchY).toInt()
                    if (kotlin.math.abs(dx) > 8 || kotlin.math.abs(dy) > 8) {
                        dragged = true
                    }
                    // gravity END: زيادة x تحرّك الفقاعة يساراً على LTR والعكس
                    params.x = (lastX - dx).coerceAtLeast(0)
                    params.y = (lastY + dy).coerceAtLeast(0)
                    try {
                        wm.updateViewLayout(view, params)
                    } catch (_: Exception) {
                    }
                    true
                }
                MotionEvent.ACTION_UP -> {
                    if (!dragged) {
                        onBubbleTap(context)
                    }
                    true
                }
                else -> false
            }
        }

        close.setOnClickListener { hide() }

        wm.addView(view, params)

        windowManager = wm
        overlayView = view
        layoutParams = params
        statusView = status
        micView = mic
        showing = true
        applyVisualState()
        Log.i(TAG, "النوافذ العائمة ظاهرة")
    }

    private fun detach() {
        val view = overlayView
        val wm = windowManager
        if (view != null && wm != null) {
            try {
                wm.removeView(view)
            } catch (_: Exception) {
            }
        }
        overlayView = null
        windowManager = null
        layoutParams = null
        statusView = null
        micView = null
        showing = false
    }

    private fun applyVisualState() {
        statusView?.text = statusText
        micView?.alpha = if (listening) 1f else 0.55f
    }

    private fun onBubbleTap(context: Context) {
        if (!VoiceManager.isListening()) {
            VoiceManager.startListening()
        }
        val launch = context.packageManager.getLaunchIntentForPackage(context.packageName)
        if (launch != null) {
            launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            try {
                context.startActivity(launch)
            } catch (e: Exception) {
                Log.w(TAG, "تعذر فتح التطبيق من الفقاعة: ${e.message}")
            }
        }
    }
}
