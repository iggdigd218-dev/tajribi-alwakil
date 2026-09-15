package com.example.app.automation

import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.os.SystemClock
import android.util.Log

/**
 * خدمة خلفية أمامية مستمرة (المرحلة 3).
 *
 *  - إشعار دائم "وكيل الأتمتة يعمل في الخلفية" يرفع أولوية العملية
 *    ويحميها من Low Memory Killer.
 *  - START_STICKY: يعيد النظام تشغيل الخدمة تلقائياً إن قُتلت.
 *  - onTaskRemoved: إعادة تشغيل مجدولة إذا سحب المستخدم التطبيق
 *    من قائمة Recents.
 */
class AgentForegroundService : Service() {

    companion object {

        private const val TAG = "AgentFGService"

        const val CHANNEL_ID = "agent_automation_channel"
        const val NOTIFICATION_ID = 1001
        const val ACTION_START = "com.example.app.automation.action.FGS_START"
        const val ACTION_STOP = "com.example.app.automation.action.FGS_STOP"

        /** هل الخدمة تعمل الآن؟ (للاستعلام من الجسور) */
        @Volatile
        var isRunning = false
            private set

        /** تشغيل الخدمة الأمامية من أي سياق. */
        @JvmStatic
        fun start(context: Context) {
            val intent = Intent(context, AgentForegroundService::class.java)
                .setAction(ACTION_START)
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (e: Exception) {
                // قيود بدء الخدمات الأمامية من الخلفية في أندرويد 12+
                Log.e(TAG, "تعذر بدء الخدمة: ${e.message}")
            }
        }

        /** إيقاف الخدمة. */
        @JvmStatic
        fun stop(context: Context) {
            context.stopService(Intent(context, AgentForegroundService::class.java))
        }
    }

    override fun onCreate() {
        super.onCreate()
        isRunning = true
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
            return START_NOT_STICKY
        }

        // ترقية العملية إلى "أمامية" بالإشعار الدائم —
        // هذه هي الحماية الأساسية من Low Memory Killer.
        startInForeground()

        // إعادة التشغيل التلقائي إن قتلها النظام
        return START_STICKY
    }

    /**
     * بدء الواجهة الأمامية بأمان على كل الإصدارات:
     * على أندرويد 14+ يتطلب نوع microphone صلاحية RECORD_AUDIO ممنوحة
     * مسبقاً — عند فشله (تشغيل الخدمة قبل منح الميكروفون) نتراجع
     * إلى نوع specialUse فقط بدل الانهيار.
     */
    private fun startInForeground() {
        val notification = buildNotification()
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                startForeground(
                    NOTIFICATION_ID, notification,
                    android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE or
                        android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (e: Exception) {
            // غالباً: نوع microphone بلا صلاحية ميكروفون بعد (أندرويد 14+)
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                    startForeground(
                        NOTIFICATION_ID, notification,
                        android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
                    )
                } else {
                    startForeground(NOTIFICATION_ID, notification)
                }
            } catch (inner: Exception) {
                Log.e(TAG, "تعذر بدء الخدمة الأمامية: ${inner.message}")
                stopSelf()
            }
        }
    }

    /** قناة الإشعارات (إلزامية من أندرويد 8+). */
    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "وكيل الأتمتة",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "قناة خدمة وكيل الأتمتة الدائمة"
                setShowBadge(false)
            }
            getSystemService(NotificationManager::class.java)
                .createNotificationChannel(channel)
        }
    }

    private fun buildNotification(): Notification {
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        val contentIntent = launchIntent?.let {
            PendingIntent.getActivity(
                this, 0, it,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            )
        }

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }

        return builder
            .setSmallIcon(
                if (applicationInfo.icon != 0) applicationInfo.icon
                else android.R.drawable.sym_def_app_icon
            )
            .setContentTitle("وكيل الأتمتة")
            .setContentText("وكيل الأتمتة يعمل في الخلفية")
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setPriority(Notification.PRIORITY_LOW)
            .setContentIntent(contentIntent)
            .build()
    }

    /**
     * حماية إضافية: إذا سحب المستخدم التطبيق من قائمة Recents
     * نجدول إعادة تشغيل الخدمة بعد ثانية واحدة.
     */
    override fun onTaskRemoved(rootIntent: Intent?) {
        val restartIntent = Intent(applicationContext, AgentForegroundService::class.java)
            .setAction(ACTION_START)
        val pendingIntent = PendingIntent.getService(
            applicationContext, 1002, restartIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_ONE_SHOT
        )
        try {
            val alarmManager = getSystemService(Context.ALARM_SERVICE) as AlarmManager
            alarmManager.setAndAllowWhileIdle(
                AlarmManager.ELAPSED_REALTIME,
                SystemClock.elapsedRealtime() + 1000L,
                pendingIntent
            )
        } catch (e: Exception) {
            Log.w(TAG, "تعذر جدولة إعادة التشغيل: ${e.message}")
        }
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        isRunning = false
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
