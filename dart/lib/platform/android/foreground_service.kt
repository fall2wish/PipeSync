package com.pipesync.app.platform.android

import android.app.Service
import android.content.Intent
import android.net.wifi.WifiManager
import android.os.IBinder
import android.os.PowerManager
import java.util.Timer
import java.util.TimerTask

/**
 * PipeSync Android 长效后台服务架构
 * 适配 Android 14/15 dataSync 6小时硬性熔断与分段接力保活
 */
class TransferForegroundService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null
    private val relayTimer = Timer()
    private val SAFE_RELAY_INTERVAL_MS = (5.5 * 60 * 60 * 1000).toLong()

    override fun onCreate() {
        super.onCreate()
        acquireLocks()
        scheduleRelayTimer()
    }

    private fun acquireLocks() {
        val powerManager = getSystemService(POWER_SERVICE) as PowerManager
        wakeLock = powerManager.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "PipeSync::TransferWakeLock").apply {
            acquire(SAFE_RELAY_INTERVAL_MS + 10000)
        }

        val wifiManager = applicationContext.getSystemService(WIFI_SERVICE) as WifiManager
        wifiLock = wifiManager.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "PipeSync::TransferWifiLock").apply {
            acquire()
        }
    }

    private fun scheduleRelayTimer() {
        relayTimer.schedule(object : TimerTask() {
            override fun run() {
                triggerRelayHandoff()
            }
        }, SAFE_RELAY_INTERVAL_MS)
    }

    private fun triggerRelayHandoff() {
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun onTimeout(startId: Int) {
        triggerRelayHandoff()
    }

    override fun onDestroy() {
        relayTimer.cancel()
        wakeLock?.let { if (it.isHeld) it.release() }
        wifiLock?.let { if (it.isHeld) it.release() }
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
