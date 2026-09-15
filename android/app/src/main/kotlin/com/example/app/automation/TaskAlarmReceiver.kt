package com.example.app.automation

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.PowerManager
import android.util.Log
import org.json.JSONObject
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * مستقبل التنبيهات الدقيقة (المرحلة 3).
 *
 * الدورة الكاملة:
 *  1. يستقبل التنبيه من AlarmManager (عبر PendingIntent جهّزه ScheduleManager).
 *  2. يستخرج بيانات المهمة: taskId / actionType / payloadJson.
 *  3. يمسك WakeLock مؤقتاً (60 ثانية كحد أقصى) حتى لا ينام المعالج
 *     أثناء تنفيذ المهمة.
 *  4. يوجّه الأمر آلياً إلى:
 *     - SystemBridgeManager  → أوامر النظام وفتح التطبيقات والمكالمات.
 *     - AgentAccessibilityService → أحداث الأتمتة (نقر/تعبئة نصوص).
 */
class TaskAlarmReceiver : BroadcastReceiver() {

    companion object {

        private const val TAG = "TaskAlarmReceiver"
        private const val WAKELOCK_TIMEOUT_MS = 60_000L

        /** خيط تنفيذ واحد — يضمن تسلسل المهام المتزامنة. */
        private val executor: ExecutorService = Executors.newSingleThreadExecutor()

        const val ACTION_TASK_ALARM = "com.example.app.automation.TASK_ALARM"
        const val EXTRA_TASK_ID = "taskId"
        const val EXTRA_ACTION_TYPE = "actionType"
        const val EXTRA_PAYLOAD_JSON = "payloadJson"
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION_TASK_ALARM) return

        val taskId = intent.getStringExtra(EXTRA_TASK_ID)
        val actionType = intent.getStringExtra(EXTRA_ACTION_TYPE)
        val payloadJson = intent.getStringExtra(EXTRA_PAYLOAD_JSON) ?: "{}"
        if (taskId.isNullOrBlank() || actionType.isNullOrBlank()) return

        // 1) WakeLock مؤقت: يضمن بقاء المعالج مستيقظاً أثناء التنفيذ
        //    (مهلة قصوى 60 ثانية ثم يُحرر تلقائياً — لا تسريب أبداً).
        val powerManager = context.getSystemService(Context.POWER_SERVICE) as PowerManager
        val wakeLock = powerManager.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK,
            "agent_automation:task:$taskId"
        ).apply {
            setReferenceCounted(false)
            acquire(WAKELOCK_TIMEOUT_MS)
        }

        // 2) goAsync + خيط منفصل: يمنحنا وقتاً أطول من 10 ثوانٍ
        //    الممنوحة للمستقبلات العادية.
        val pendingResult = goAsync()
        executor.execute {
            try {
                routeTask(taskId, actionType, payloadJson)
            } catch (e: Exception) {
                Log.e(TAG, "فشل تنفيذ المهمة [$taskId]: ${e.message}", e)
            } finally {
                if (wakeLock.isHeld) wakeLock.release()
                pendingResult.finish()
            }
        }
    }

    // ═══════════════════════════════════════════
    //  توجيه المهمة إلى الجهة المنفذة
    // ═══════════════════════════════════════════

    private fun routeTask(taskId: String, actionType: String, payloadJson: String) {
        val payload = try {
            JSONObject(payloadJson)
        } catch (e: Exception) {
            JSONObject()
        }
        Log.i(TAG, "▶ تنفيذ المهمة [$taskId] | النوع: $actionType | البيانات: $payloadJson")

        when (actionType) {

            // ── أوامر النظام عبر Shizuku ──
            SystemBridgeManager.ACTION_SHELL_COMMAND -> {
                val command = payload.optString("command")
                if (command.isNotBlank()) {
                    logResult(taskId, SystemBridgeManager.executeShellCommand(command))
                }
            }

            SystemBridgeManager.ACTION_TOGGLE_MOBILE_DATA ->
                logResult(
                    taskId,
                    SystemBridgeManager.toggleMobileData(payload.optBoolean("enable", true))
                )

            SystemBridgeManager.ACTION_TOGGLE_WIFI ->
                logResult(
                    taskId,
                    SystemBridgeManager.toggleWifi(payload.optBoolean("enable", true))
                )

            SystemBridgeManager.ACTION_OPEN_APP -> {
                val packageName = payload.optString("packageName")
                if (packageName.isNotBlank()) {
                    logResult(
                        taskId,
                        SystemBridgeManager.launchApp(
                            packageName,
                            payload.optString("activity").takeIf { it.isNotBlank() },
                            extrasOf(payload.optJSONObject("extras"))
                        )
                    )
                } else {
                    Log.w(TAG, "[$taskId] packageName مفقود في البيانات")
                }
            }

            SystemBridgeManager.ACTION_CALL ->
                logResult(
                    taskId,
                    SystemBridgeManager.dialCallViaSlot(
                        payload.optString("phoneNumber"),
                        payload.optInt("slotIndex", 0)
                    )
                )

            SystemBridgeManager.ACTION_INPUT_TAP ->
                logResult(
                    taskId,
                    SystemBridgeManager.inputTap(payload.optInt("x"), payload.optInt("y"))
                )

            SystemBridgeManager.ACTION_INPUT_TEXT ->
                logResult(taskId, SystemBridgeManager.inputText(payload.optString("text")))

            // ── أحداث الأتمتة عبر AccessibilityService ──
            SystemBridgeManager.ACTION_UI_CLICK -> {
                val service = AgentAccessibilityService.instance
                if (service == null) {
                    Log.w(TAG, "[$taskId] خدمة الإمكانية غير مفعّلة — تعذّر ui_click")
                    // احتياطي: نقرة بالإحداثيات عبر Shizuku إن وُجدت
                    if (payload.has("x") && payload.has("y")) {
                        SystemBridgeManager.inputTap(payload.optInt("x"), payload.optInt("y"))
                    }
                    return
                }
                val viewId = payload.optString("viewId")
                val node = if (viewId.isNotBlank()) {
                    service.findNodeById(viewId)
                } else {
                    service.findNodeByText(payload.optString("text"))
                }
                if (node != null) {
                    logResult(taskId, "ui_click: ${service.clickNode(node)}")
                } else if (payload.has("x") && payload.has("y")) {
                    // احتياطي: النقر بالإحداثيات إذا لم يُعثر على العنصر
                    logResult(
                        taskId,
                        SystemBridgeManager.inputTap(payload.optInt("x"), payload.optInt("y"))
                    )
                } else {
                    Log.w(TAG, "[$taskId] لم يُعثر على العنصر المطلوب بالنقر")
                }
            }

            SystemBridgeManager.ACTION_UI_SET_TEXT -> {
                val service = AgentAccessibilityService.instance
                if (service == null) {
                    Log.w(TAG, "[$taskId] خدمة الإمكانية غير مفعّلة — تعذّر ui_set_text")
                    return
                }
                val viewId = payload.optString("viewId")
                val node = if (viewId.isNotBlank()) {
                    service.findNodeById(viewId)
                } else {
                    service.findNodeByText(payload.optString("text"))
                }
                if (node != null) {
                    logResult(
                        taskId,
                        "ui_set_text: ${service.setText(node, payload.optString("value"))}"
                    )
                } else {
                    Log.w(TAG, "[$taskId] لم يُعثر على الحقل المطلوب")
                }
            }

            else -> Log.w(TAG, "[$taskId] نوع مهمة غير معروف: $actionType")
        }
    }

    // ═══════════════════════════════════════════
    //  أدوات مساعدة
    // ═══════════════════════════════════════════

    private fun extrasOf(json: JSONObject?): Map<String, String>? {
        if (json == null || json.length() == 0) return null
        val map = mutableMapOf<String, String>()
        for (key in json.keys()) map[key] = json.optString(key)
        return map
    }

    private fun logResult(taskId: String, output: String) {
        Log.i(TAG, "[$taskId] النتيجة: $output")
    }
}
