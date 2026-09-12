package com.pipesync.app.platform.android

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.util.Log
import com.pipesync.app.MainActivity
import com.pipesync.app.PipeSyncApplication
import java.util.Timer
import java.util.TimerTask

/**
 * PipeSync Android 长效后台服务架构
 * 适配 Android 14/15 dataSync 6小时硬性熔断与分段接力保活 (Section 5.1 & Section 1)
 */
class TransferForegroundService : Service() {

    companion object {
        private const val TAG = "TransferForegroundSvc"
        private const val NOTIFICATION_ID = 1001
        const val ACTION_START = "com.pipesync.action.START"
        const val ACTION_STOP = "com.pipesync.action.STOP"

        fun start(context: Context) {
            val intent = Intent(context, TransferForegroundService::class.java).apply {
                action = ACTION_START
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            val intent = Intent(context, TransferForegroundService::class.java).apply {
                action = ACTION_STOP
            }
            context.stopService(intent)
        }
    }

    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null
    private val relayTimer = Timer()
    // 5.5 小时接力间隔，主动在 6 小时熔断前重置前台服务会话
    private val SAFE_RELAY_INTERVAL_MS = (5.5 * 60 * 60 * 1000).toLong()

    override fun onCreate() {
        super.onCreate()
        Log.i(TAG, "Creating TransferForegroundService...")
        startAsForeground()
        acquireLocks()
        scheduleRelayTimer()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            Log.i(TAG, "Stopping service via intent...")
            stopSelf()
            return START_NOT_STICKY
        }
        return START_STICKY
    }

    private fun startAsForeground() {
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val notificationBuilder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, PipeSyncApplication.CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }

        val notification = notificationBuilder
            .setContentTitle("PipeSync 数据管道正在运行")
            .setContentText("2PC 强一致性传输引擎与 WebKit 守护进程活跃中")
            .setSmallIcon(com.pipesync.app.R.drawable.ic_pipesync_logo)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .build()

        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
            Log.i(TAG, "Foreground notification started with type DATA_SYNC.")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to startForeground with DATA_SYNC: ${e.message}", e)
            try {
                // Fallback to normal foreground without type
                startForeground(NOTIFICATION_ID, notification)
            } catch (fallbackEx: Exception) {
                Log.e(TAG, "Fallback startForeground failed: ${fallbackEx.message}", fallbackEx)
            }
        }
    }

    private fun acquireLocks() {
        try {
            val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = powerManager.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK,
                "PipeSync::TransferWakeLock"
            ).apply {
                acquire(SAFE_RELAY_INTERVAL_MS + 10000)
            }

            val wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            wifiLock = wifiManager.createWifiLock(
                WifiManager.WIFI_MODE_FULL_HIGH_PERF,
                "PipeSync::TransferWifiLock"
            ).apply {
                acquire()
            }
            Log.i(TAG, "WakeLock and WifiLock acquired.")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to acquire locks: ${e.message}", e)
        }
    }

    private fun scheduleRelayTimer() {
        relayTimer.schedule(object : TimerTask() {
            override fun run() {
                Log.w(TAG, "5.5-hour relay window reached. Triggering relay handoff to avoid 6h OS cutoff.")
                triggerRelayHandoff()
            }
        }, SAFE_RELAY_INTERVAL_MS)
    }

    private fun triggerRelayHandoff() {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                stopForeground(STOP_FOREGROUND_REMOVE)
            } else {
                @Suppress("DEPRECATION")
                stopForeground(true)
            }
            // 重新拉起自身以重置 Android 14/15 6小时数据同步计数器
            val nextIntent = Intent(this, TransferForegroundService::class.java).apply {
                action = ACTION_START
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(nextIntent)
            } else {
                startService(nextIntent)
            }
            stopSelf()
        } catch (e: Exception) {
            Log.e(TAG, "Relay handoff error: ${e.message}", e)
        }
    }

    // Android 14+ timeout callback if OS cuts off dataSync
    override fun onTimeout(startId: Int) {
        Log.w(TAG, "System triggered onTimeout for dataSync service. Re-dispatching relay.")
        triggerRelayHandoff()
    }

    override fun onDestroy() {
        relayTimer.cancel()
        wakeLock?.let { if (it.isHeld) it.release() }
        wifiLock?.let { if (it.isHeld) it.release() }
        Log.i(TAG, "TransferForegroundService destroyed and locks released.")
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
