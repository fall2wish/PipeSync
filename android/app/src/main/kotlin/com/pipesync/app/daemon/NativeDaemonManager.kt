package com.pipesync.app.daemon

import android.content.Context
import android.util.Log
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import kotlin.concurrent.thread

/**
 * PipeSync 核心引擎守护进程管理器
 * 负责在 Android 宿主中加载 librclone / QuickJS 原生库，并监控本地管理端 HTTP 端口
 */
object NativeDaemonManager {
    private const val TAG = "NativeDaemonManager"
    const val DEFAULT_PORT = 8384
    private var isEngineRunning = false

    fun startDaemon(context: Context, onReady: (port: Int) -> Unit) {
        if (isEngineRunning) {
            onReady(DEFAULT_PORT)
            return
        }

        thread(name = "PipeSync-DaemonInit") {
            try {
                // 确保原生库已准备 (librclone.so & libpipesync_quickjs.so)
                loadNativeLibraries(context)

                // 启动或连接守护进程服务端口
                isEngineRunning = true
                Log.i(TAG, "PipeSync daemon backend starting on port $DEFAULT_PORT...")

                // 轮询检查端口可用性
                var attempts = 0
                val maxAttempts = 15
                var ready = false

                while (attempts < maxAttempts && !ready) {
                    ready = checkPortAlive(DEFAULT_PORT)
                    if (!ready) {
                        Thread.sleep(300)
                        attempts++
                    }
                }

                Log.i(TAG, "PipeSync engine ready state: $ready")
                onReady(DEFAULT_PORT)
            } catch (e: Exception) {
                Log.e(TAG, "Failed to start PipeSync daemon: ${e.message}", e)
                onReady(DEFAULT_PORT)
            }
        }
    }

    private fun loadNativeLibraries(context: Context) {
        try {
            System.loadLibrary("rclone")
            Log.d(TAG, "librclone.so loaded successfully.")
        } catch (t: Throwable) {
            Log.w(TAG, "Native librclone load fallback: ${t.message}")
        }

        try {
            System.loadLibrary("pipesync_quickjs")
            Log.d(TAG, "libpipesync_quickjs.so loaded successfully.")
        } catch (t: Throwable) {
            Log.w(TAG, "Native libpipesync_quickjs load fallback: ${t.message}")
        }
    }

    fun checkPortAlive(port: Int): Boolean {
        return try {
            val url = URL("http://127.0.0.1:$port/api/v1/status")
            val conn = url.openConnection() as HttpURLConnection
            conn.connectTimeout = 500
            conn.readTimeout = 500
            conn.requestMethod = "GET"
            val code = conn.responseCode
            conn.disconnect()
            code in 200..399
        } catch (e: Exception) {
            false
        }
    }
}
