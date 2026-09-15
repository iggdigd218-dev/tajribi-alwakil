package com.example.app.automation

import android.content.Context
import android.content.Intent
import android.graphics.Rect
import android.provider.Settings
import android.view.accessibility.AccessibilityNodeInfo
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * جسر التواصل بين Flutter وخدمة الأتمتة عبر MethodChannel.
 *
 * قناة التحكم: `com.example.app/accessibility_automation`
 * (يجب أن يطابق الاسمَ المعرف في كود Dart).
 *
 * التسجيل: يُستدعى [register] مرة واحدة من `MainActivity.configureFlutterEngine()`.
 *
 * الأوامر المدعومة:
 * ─ isServiceRunning          → هل الخدمة مفعّلة ومتصلة؟
 * ─ openAccessibilitySettings → فتح إعدادات إمكانية الوصول في النظام.
 * ─ getActiveWindow           → معلومات آخر نافذة نشطة.
 * ─ findNodeByText {text}     → بحث بالنص (يعيد وصف العنصر + مقبض handle).
 * ─ findNodeById {viewId}     → بحث بمعرّف العرض.
 * ─ clickNode {handle}        → نقر عنصر مُسجَّل.
 * ─ setText {handle, text}    → تعبئة حقل نصي.
 * ─ clickAtCoordinates {x, y} → نقرة بإحداثيات الشاشة.
 */
object AutomationBridge : MethodChannel.MethodCallHandler {

    /** اسم القناة — يجب أن يطابق الاسم في accessibility_bridge.dart */
    const val CHANNEL = "com.example.app/accessibility_automation"

    private var channel: MethodChannel? = null
    private var appContext: Context? = null

    /**
     * تسجيل الجسر على محرك Flutter الحالي.
     * يُستدعى من `MainActivity.configureFlutterEngine()` (يدعم إعادة إنشاء المحرك).
     */
    @JvmStatic
    fun register(context: Context, messenger: BinaryMessenger) {
        appContext = context.applicationContext
        // فصل أي تسجيل سابق (تدوير الشاشة / إعادة التشغيل السريع)
        channel?.setMethodCallHandler(null)
        channel = MethodChannel(messenger, CHANNEL).also {
            it.setMethodCallHandler(this)
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            handle(call, result)
        } catch (e: Exception) {
            result.error("NATIVE_ERROR", e.message ?: e.javaClass.simpleName, null)
        }
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {

            "isServiceRunning" ->
                result.success(AgentAccessibilityService.isRunning)

            "openAccessibilitySettings" -> {
                val ok = try {
                    appContext?.startActivity(
                        Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    )
                    true
                } catch (e: Exception) {
                    logError(e)
                    false
                }
                result.success(ok)
            }

            "getActiveWindow" -> withService(result) { service ->
                result.success(
                    mapOf(
                        "packageName" to (service.lastWindowPackage
                            ?: service.rootInActiveWindow?.packageName?.toString()),
                        "className" to service.lastWindowClass
                    )
                )
            }

            "findNodeByText", "findNodeById" -> withService(result) { service ->
                val node = if (call.method == "findNodeByText") {
                    val text = call.argument<String>("text")
                        ?: throw IllegalArgumentException("الوسيط 'text' مفقود")
                    service.findNodeByText(text)
                } else {
                    val viewId = call.argument<String>("viewId")
                        ?: throw IllegalArgumentException("الوسيط 'viewId' مفقود")
                    service.findNodeById(viewId)
                }
                result.success(node?.toMap())
            }

            "clickNode" -> withNode(result, call) { service, node ->
                result.success(service.clickNode(node))
            }

            "setText" -> withNode(result, call) { service, node ->
                val text = call.argument<String>("text")
                    ?: throw IllegalArgumentException("الوسيط 'text' مفقود")
                result.success(service.setText(node, text))
            }

            "clickAtCoordinates" -> {
                val x = call.argument<Number>("x")?.toFloat()
                val y = call.argument<Number>("y")?.toFloat()
                if (x == null || y == null) {
                    result.error("INVALID_ARGUMENTS", "الوسيطان 'x' و 'y' مطلوبان", null)
                    return
                }
                withService(result) { service ->
                    result.success(service.clickAtCoordinates(x, y))
                }
            }

            else -> result.notImplemented()
        }
    }

    // ─────────────────────────────────────────────────────────────
    //  أدوات مساعدة
    // ─────────────────────────────────────────────────────────────

    /** تنفيذ الكتلة فقط إذا كانت خدمة الأتمتة مفعّلة، وإلا خطأ SERVICE_NOT_ENABLED. */
    private inline fun withService(
        result: MethodChannel.Result,
        block: (AgentAccessibilityService) -> Unit
    ) {
        val service = AgentAccessibilityService.instance
        if (service == null) {
            result.error(
                "SERVICE_NOT_ENABLED",
                "خدمة الأتمتة غير مفعّلة بعد. فعّلها من إعدادات النظام.",
                null
            )
        } else {
            block(service)
        }
    }

    /** مثل [withService] مع استرجاع عنصر مسجّل عبر مقبضه والتحقق من صلاحيته. */
    private inline fun withNode(
        result: MethodChannel.Result,
        call: MethodCall,
        block: (AgentAccessibilityService, AccessibilityNodeInfo) -> Unit
    ) {
        withService(result) { service ->
            val handle = call.argument<Int>("handle")
                ?: throw IllegalArgumentException("الوسيط 'handle' مفقود")
            val node = NodeRegistry.resolve(handle)
            if (node == null) {
                result.error(
                    "NODE_NOT_FOUND",
                    "العنصر غير موجود أو انتهت صلاحيته (handle=$handle)",
                    null
                )
            } else {
                block(service, node)
            }
        }
    }

    /** تحويل العنصر إلى خريطة قابلة للإرسال إلى Dart، مع تسجيله في السجل. */
    private fun AccessibilityNodeInfo.toMap(): Map<String, Any?> {
        val rect = Rect()
        getBoundsInScreen(rect)
        return mapOf(
            "handle" to NodeRegistry.put(this),
            "text" to text?.toString(),
            "viewId" to viewIdResourceName,
            "className" to className?.toString(),
            "packageName" to packageName?.toString(),
            "contentDescription" to contentDescription?.toString(),
            "clickable" to isClickable,
            "editable" to isEditable,
            "scrollable" to isScrollable,
            "bounds" to mapOf(
                "left" to rect.left,
                "top" to rect.top,
                "right" to rect.right,
                "bottom" to rect.bottom
            )
        )
    }

    private fun logError(e: Exception) {
        android.util.Log.e("AutomationBridge", "خطأ في تنفيذ الأمر", e)
    }
}

/**
 * سجل مؤقت للعناصر المكتشفة: يمنح كل عنصر "مقبضاً" (handle) رقمياً
 * يُمرَّر إلى Dart ويعاد استخدامه في clickNode/setText، لأن كائنات
 * AccessibilityNodeInfo لا يمكن تمريرها عبر MethodChannel مباشرة.
 *
 * - سعة قصوى (LRU) تُنظّف تلقائياً لمنع تراكم المراجع.
 * - [resolve] تتحقق من صلاحية العنصر (refresh) قبل إعادته،
 *   وتحذفه من السجل إذا كانت شاشته لم تعد قائمة.
 */
private object NodeRegistry {

    private const val MAX_ENTRIES = 64

    private val nodes = LinkedHashMap<Int, AccessibilityNodeInfo>(16, 0.75f, true)
    private var nextHandle = 1

    @Synchronized
    fun put(node: AccessibilityNodeInfo): Int {
        trimIfNeeded()
        val handle = nextHandle++
        nodes[handle] = node
        return handle
    }

    /** إرجاع العنصر بعد التأكد أنه ما يزال صالحاً، أو null. */
    @Synchronized
    fun resolve(handle: Int): AccessibilityNodeInfo? {
        val node = nodes[handle] ?: return null
        val isFresh = try {
            node.refresh()
        } catch (e: Exception) {
            false
        }
        if (!isFresh) {
            nodes.remove(handle)
            return null
        }
        return node
    }

    @Synchronized
    fun clear() = nodes.clear()

    @Synchronized
    private fun trimIfNeeded() {
        val it = nodes.entries.iterator()
        while (nodes.size >= MAX_ENTRIES && it.hasNext()) {
            it.next()
            it.remove()
        }
    }
}
