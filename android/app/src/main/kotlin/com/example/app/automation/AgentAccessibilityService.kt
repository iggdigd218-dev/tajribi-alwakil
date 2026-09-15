package com.example.app.automation

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.content.Intent
import android.graphics.Path
import android.graphics.Rect
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo

/**
 * نواة محرك الأتمتة — خدمة إمكانية وصول تمنح التطبيق القدرة على:
 *
 *  - البحث عن العناصر في واجهة أي تطبيق (بالنص أو بمعرّف العرض).
 *  - محاكاة النقر على العناصر أو النقر بالإحداثيات (dispatchGesture).
 *  - تعبئة الحقول النصية (ACTION_SET_TEXT).
 *
 * الوصول الثابت للخدمة من أي مكان في التطبيق أثناء تفعيلها:
 *  AgentAccessibilityService.instance
 */
class AgentAccessibilityService : AccessibilityService() {

    companion object {

        private const val TAG = "AgentA11yService"

        /** مدة الضغط أثناء محاكاة النقرة (بالميلي ثانية). */
        private const val CLICK_DURATION_MS = 100L

        /**
         * المرجع الثابت (Singleton) للخدمة — لا يكون متاحاً
         * إلا بعد تفعيلها من إعدادات النظام.
         */
        @JvmStatic
        @Volatile
        var instance: AgentAccessibilityService? = null
            private set

        /** هل الخدمة مفعّلة من إعدادات النظام ومتصلة الآن؟ */
        @JvmStatic
        val isRunning: Boolean
            get() = instance != null
    }

    /** آخر حزمة نشطة رصدتها الخدمة (تُحدَّث مع كل حدث يصل). */
    @Volatile
    var lastWindowPackage: String? = null
        private set

    /** آخر فئة نافذة نشطة رصدتها الخدمة. */
    @Volatile
    var lastWindowClass: String? = null
        private set

    // ─────────────────────────────────────────────────────────────
    //  دورة حياة الخدمة
    // ─────────────────────────────────────────────────────────────

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
        Log.i(TAG, "خدمة الأتمتة متصلة وجاهزة ✅")
    }

    override fun onUnbind(intent: Intent): Boolean {
        // تُستدعى عندما يوقف المستخدم الخدمة من إعدادات النظام
        instance = null
        Log.i(TAG, "خدمة الأتمتة مفصولة ⛔")
        return super.onUnbind(intent)
    }

    override fun onDestroy() {
        instance = null
        super.onDestroy()
    }

    override fun onInterrupt() {
        Log.w(TAG, "تمت مقاطعة الخدمة (onInterrupt)")
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent) {
        // المرحلة 1: نكتفي بتتبّع النافذة النشطة.
        // (يمكن في مراحل لاحقة بثّ هذه الأحداث إلى Flutter.)
        event.packageName?.let { lastWindowPackage = it.toString() }
        event.className?.let { lastWindowClass = it.toString() }
    }

    // ─────────────────────────────────────────────────────────────
    //  واجهة محرك الأتمتة (تُستدعى من AutomationBridge)
    // ─────────────────────────────────────────────────────────────

    /** جذر شجرة العناصر للنافذة النشطة حالياً. */
    private fun root(): AccessibilityNodeInfo? = rootInActiveWindow

    /**
     * البحث عن أول عنصر نصّه أو وصفه المحتوى يحتوي على [text]
     * (بحث جزئي غير حساس لحالة الأحرف).
     *
     * يعيد `null` إن لم يُعثر على العنصر أو لم تكن هناك نافذة نشطة.
     */
    fun findNodeByText(text: String): AccessibilityNodeInfo? {
        val root = root() ?: return null
        return try {
            root.findAccessibilityNodeInfosByText(text)
                .firstOrNull { node ->
                    node.text?.toString()?.contains(text, ignoreCase = true) == true ||
                        node.contentDescription?.toString()
                            ?.contains(text, ignoreCase = true) == true
                }
        } catch (e: Exception) {
            Log.e(TAG, "findNodeByText: فشل البحث عن \"$text\"", e)
            null
        }
    }

    /**
     * البحث عن أول عنصر عبر معرّف العرض بالصيغة الكاملة:
     * `"com.example.target:id/button_submit"`
     *
     * يتطلب تفعيل `flagReportViewIds` في ملف التهيئة.
     */
    fun findNodeById(viewId: String): AccessibilityNodeInfo? {
        val root = root() ?: return null
        return try {
            root.findAccessibilityNodeInfosByViewId(viewId).firstOrNull()
        } catch (e: Exception) {
            Log.e(TAG, "findNodeById: فشل البحث عن \"$viewId\"", e)
            null
        }
    }

    /**
     * محاكاة النقر على عنصر:
     *
     * 1. `ACTION_CLICK` على العنصر إن كان قابلاً للنقر،
     *    وإلا نصعد لأقرب والد قابل للنقر.
     * 2. إن تعذّر ذلك كلياً، نقرة إحداثية على مركز العنصر
     *    عبر [dispatchGesture].
     */
    fun clickNode(node: AccessibilityNodeInfo): Boolean {
        // 1) محاولة النقر المنطقي (الطريقة المفضلة)
        var current: AccessibilityNodeInfo? = node
        while (current != null) {
            if (current.isClickable &&
                current.performAction(AccessibilityNodeInfo.ACTION_CLICK)
            ) {
                return true
            }
            current = current.parent
        }

        // 2) احتياطي: نقرة فيزيائية على مركز إحداثيات العنصر
        val rect = Rect()
        node.getBoundsInScreen(rect)
        if (rect.isEmpty) return false
        return clickAtCoordinates(rect.exactCenterX(), rect.exactCenterY())
    }

    /**
     * كتابة نص داخل حقل نصي عبر `ACTION_SET_TEXT`
     * (يستبدل المحتوى الحالي للحقل بالكامل).
     */
    fun setText(node: AccessibilityNodeInfo, text: String): Boolean {
        return try {
            // تركيز الحقل أولاً لضمان قبول الإدخال
            node.performAction(AccessibilityNodeInfo.ACTION_FOCUS)

            val args = Bundle().apply {
                putCharSequence(
                    AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE,
                    text
                )
            }
            node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)
        } catch (e: Exception) {
            Log.e(TAG, "setText: فشل تعيين النص", e)
            false
        }
    }

    /**
     * تنفيذ نقرة بإحداثيات شاشة مطلقة عبر [dispatchGesture].
     *
     * يتطلب `canPerformGestures="true"` في ملف التهيئة،
     * ويعمل على Android 7.0 (API 24) فما فوق.
     */
    fun clickAtCoordinates(x: Float, y: Float): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) {
            Log.w(TAG, "clickAtCoordinates: dispatchGesture يتطلب API 24+")
            return false
        }
        return try {
            val path = Path().apply {
                moveTo(x, y)
                lineTo(x, y)
            }
            val gesture = GestureDescription.Builder()
                .addStroke(GestureDescription.StrokeDescription(path, 0, CLICK_DURATION_MS))
                .build()
            dispatchGesture(gesture, null, null)
        } catch (e: Exception) {
            Log.e(TAG, "clickAtCoordinates: فشل الإيماءة عند ($x, $y)", e)
            false
        }
    }
}
