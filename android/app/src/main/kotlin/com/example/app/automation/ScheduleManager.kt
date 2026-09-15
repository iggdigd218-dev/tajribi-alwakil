package com.example.app.automation

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log

/**
 * مدير الجدولة الدقيقة (المرحلة 3).
 *
 *  - يستخدم AlarmManager.setExactAndAllowWhileIdle لضمان الدقة
 *    بالثانية واختراق Doze Mode.
 *  - يجهّز PendingIntent يحمل بيانات المهمة (taskId / actionType /
 *    payloadJson) ويوجهها إلى TaskAlarmReceiver.
 *  - على أندرويد 12+ تتطلب التنبيهات الدقيقة صلاحية خاصة
 *    (SCHEDULE_EXACT_ALARM) — إن لم تكن ممنوحة نستخدم أقرب بديل
 *    غير دقيق (setAndAllowWhileIdle) مع تسجيل تحذير.
 */
object ScheduleManager {

    private const val TAG = "ScheduleManager"

    /**
     * جدولة مهمة دقيقة.
     *
     * @param taskId          معرّف فريد للمهمة (يُستخدم للإلغاء لاحقاً).
     * @param triggerAtMillis وقت التنفيذ بالميلي ثانية (System.currentTimeMillis).
     * @param actionType      نوع الأمر (من ثوابت SystemBridgeManager).
     * @param payload         سلسلة JSON تحمل معاملات التنفيذ.
     */
    fun scheduleExactTask(
        context: Context,
        taskId: String,
        triggerAtMillis: Long,
        actionType: String,
        payload: String
    ): Boolean {
        val alarmManager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager

        val intent = Intent(context, TaskAlarmReceiver::class.java).apply {
            action = TaskAlarmReceiver.ACTION_TASK_ALARM
            putExtra(TaskAlarmReceiver.EXTRA_TASK_ID, taskId)
            putExtra(TaskAlarmReceiver.EXTRA_ACTION_TYPE, actionType)
            putExtra(TaskAlarmReceiver.EXTRA_PAYLOAD_JSON, payload)
        }

        val pendingIntent = PendingIntent.getBroadcast(
            context,
            taskId.hashCode(), // معرّف فريد لكل مهمة على مستوى النظام
            intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
                !alarmManager.canScheduleExactAlarms()
            ) {
                Log.w(
                    TAG,
                    "صلاحية التنبيهات الدقيقة غير ممنوحة — سيتم استخدام تنبيه غير دقيق"
                )
                alarmManager.setAndAllowWhileIdle(
                    AlarmManager.RTC_WAKEUP, triggerAtMillis, pendingIntent
                )
            } else {
                alarmManager.setExactAndAllowWhileIdle(
                    AlarmManager.RTC_WAKEUP, triggerAtMillis, pendingIntent
                )
            }
            Log.i(
                TAG,
                "✔ تمت جدولة المهمة [$taskId] | النوع: $actionType | عند: $triggerAtMillis"
            )
            true
        } catch (e: Exception) {
            Log.e(TAG, "فشلت جدولة المهمة [$taskId]", e)
            false
        }
    }

    /** إلغاء أي مهمة مجدولة عبر معرّفها الخاص. */
    fun cancelTask(context: Context, taskId: String): Boolean {
        return try {
            val alarmManager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            val intent = Intent(context, TaskAlarmReceiver::class.java).apply {
                action = TaskAlarmReceiver.ACTION_TASK_ALARM
            }
            val pendingIntent = PendingIntent.getBroadcast(
                context,
                taskId.hashCode(),
                intent,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            )
            alarmManager.cancel(pendingIntent)
            pendingIntent.cancel()
            Log.i(TAG, "✔ تم إلغاء المهمة [$taskId]")
            true
        } catch (e: Exception) {
            Log.e(TAG, "فشل إلغاء المهمة [$taskId]", e)
            false
        }
    }

    /** هل صلاحية التنبيهات الدقيقة ممنوحة؟ (دائماً true قبل أندرويد 12) */
    fun isExactAlarmAllowed(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return true
        val alarmManager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        return alarmManager.canScheduleExactAlarms()
    }
}
