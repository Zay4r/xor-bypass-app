package com.example.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.app.usage.UsageEvents
import android.app.usage.UsageStatsManager
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log

class AppMonitorService : Service() {
    private val handler = Handler(Looper.getMainLooper())
    private lateinit var usageStatsManager: UsageStatsManager
    private var lastQueryTime = 0L
    private var targetAppActive = false
    private var disconnectScheduled = false

    private val disconnectRunnable = Runnable {
        disconnectScheduled = false
        if (!targetAppActive) {
            Log.d(TAG, "Target app left; disconnecting VPN")
            VpnActions.stopVpn(this)
        }
    }

    private val monitorRunnable = object : Runnable {
        override fun run() {
            checkForegroundApp()
            handler.postDelayed(this, POLL_INTERVAL_MS)
        }
    }

    override fun onCreate() {
        super.onCreate()
        usageStatsManager = getSystemService(UsageStatsManager::class.java)
        lastQueryTime = System.currentTimeMillis() - INITIAL_LOOKBACK_MS
        startMonitorNotification()
        handler.post(monitorRunnable)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        handler.removeCallbacks(monitorRunnable)
        handler.removeCallbacks(disconnectRunnable)
        super.onDestroy()
    }

    private fun checkForegroundApp() {
        val now = System.currentTimeMillis()
        val events = usageStatsManager.queryEvents(lastQueryTime, now)
        lastQueryTime = now

        var latestPackage: String? = null
        val event = UsageEvents.Event()
        while (events.hasNextEvent()) {
            events.getNextEvent(event)
            if (event.eventType == UsageEvents.Event.ACTIVITY_RESUMED ||
                event.eventType == UsageEvents.Event.MOVE_TO_FOREGROUND
            ) {
                latestPackage = event.packageName
            }
        }

        latestPackage?.let(::handleForegroundPackage)
    }

    private fun handleForegroundPackage(packageName: String) {
        val targetPackages = VpnActions.monitorTargetPackages(this)
        if (targetPackages.isEmpty()) {
            stopSelf()
            return
        }
        val isTarget = packageName in targetPackages

        if (isTarget && !targetAppActive) {
            targetAppActive = true
            disconnectScheduled = false
            handler.removeCallbacks(disconnectRunnable)
            Log.d(TAG, "Target app opened: $packageName; connecting VPN")
            VpnActions.startVpn(this)
        } else if (!isTarget && targetAppActive) {
            targetAppActive = false
            if (!disconnectScheduled) {
                disconnectScheduled = true
                handler.postDelayed(disconnectRunnable, DISCONNECT_DELAY_MS)
            }
        }
    }

    private fun startMonitorNotification() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                NOTIFICATION_CHANNEL,
                "Automatic VPN",
                NotificationManager.IMPORTANCE_LOW,
            )
            getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
        }

        val openAppIntent = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, NOTIFICATION_CHANNEL)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }

        val notification = builder
            .setContentTitle("HtetVPN automation")
            .setContentText("Watching for selected apps")
            .setSmallIcon(android.R.drawable.ic_lock_idle_lock)
            .setContentIntent(openAppIntent)
            .setOngoing(true)
            .build()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    companion object {
        private const val TAG = "AppMonitorService"
        private const val NOTIFICATION_CHANNEL = "app_monitor"
        private const val NOTIFICATION_ID = 2
        private const val POLL_INTERVAL_MS = 750L
        private const val INITIAL_LOOKBACK_MS = 5_000L
        private const val DISCONNECT_DELAY_MS = 1_200L

    }
}
