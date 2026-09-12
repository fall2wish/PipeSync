package com.pipesync.app.bridge

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.PowerManager
import android.provider.Settings
import android.webkit.JavascriptInterface
import android.widget.Toast
import androidx.core.content.ContextCompat
import com.pipesync.app.platform.android.MediaStoreSyncHelper
import org.json.JSONObject

/**
 * PipeSync 原生与 WebKit 交互桥接层 (JavaScriptInterface)
 * 在前端中映射为 window.PipeSyncNative
 */
class PipeSyncNativeBridge(
    private val activity: Activity,
    private val daemonPort: Int = 8384
) {

    /**
     * 检测是否具有底层存储访问权限 (MANAGE_EXTERNAL_STORAGE)
     */
    @JavascriptInterface
    fun isStoragePermissionGranted(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            Environment.isExternalStorageManager()
        } else {
            ContextCompat.checkSelfPermission(
                activity,
                android.Manifest.permission.WRITE_EXTERNAL_STORAGE
            ) == PackageManager.PERMISSION_GRANTED
        }
    }

    /**
     * 发起申请所有文件访问权限 (跨应用同步相册、下载等公共目录)
     */
    @JavascriptInterface
    fun requestStoragePermission() {
        activity.runOnUiThread {
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    val intent = Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION).apply {
                        data = Uri.parse("package:${activity.packageName}")
                    }
                    activity.startActivity(intent)
                } else {
                    activity.requestPermissions(
                        arrayOf(
                            android.Manifest.permission.READ_EXTERNAL_STORAGE,
                            android.Manifest.permission.WRITE_EXTERNAL_STORAGE
                        ),
                        101
                    )
                }
            } catch (e: Exception) {
                // 部分定制ROM可能无针对特定包名的直接页面，回退到全局列表
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    val intent = Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION)
                    activity.startActivity(intent)
                }
            }
        }
    }

    /**
     * 检测是否已加入系统电池优化白名单 (避免后台休眠中断同步)
     */
    @JavascriptInterface
    fun isBatteryOptimizationIgnored(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val powerManager = activity.getSystemService(Context.POWER_SERVICE) as PowerManager
            return powerManager.isIgnoringBatteryOptimizations(activity.packageName)
        }
        return true
    }

    /**
     * 发起申请加入电池优化白名单
     */
    @JavascriptInterface
    fun requestIgnoreBatteryOptimizations() {
        activity.runOnUiThread {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                try {
                    val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                        data = Uri.parse("package:${activity.packageName}")
                    }
                    activity.startActivity(intent)
                } catch (e: Exception) {
                    Toast.makeText(activity, "请在系统设置中为 PipeSync 允许无限制后台运行", Toast.LENGTH_LONG).show()
                }
            }
        }
    }

    /**
     * 消除物理文件删除后在系统相册留存的“幽灵缩略图”
     */
    @JavascriptInterface
    fun cleanUpMediaStore(targetPath: String) {
        MediaStoreSyncHelper.cleanUpMediaStore(activity, targetPath)
    }

    /**
     * 显示 Android 原生 Toast 消息
     */
    @JavascriptInterface
    fun showToast(message: String) {
        activity.runOnUiThread {
            Toast.makeText(activity, message, Toast.LENGTH_SHORT).show()
        }
    }

    /**
     * 返回设备硬件与系统版本 JSON 信息
     */
    @JavascriptInterface
    fun getPlatformDetails(): String {
        val obj = JSONObject()
        obj.put("platform", "android")
        obj.put("osVersion", "Android ${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT})")
        obj.put("model", "${Build.MANUFACTURER} ${Build.MODEL}")
        obj.put("isAllFilesGranted", isStoragePermissionGranted())
        obj.put("isBatteryIgnored", isBatteryOptimizationIgnored())
        obj.put("daemonPort", daemonPort)
        return obj.toString()
    }

    /**
     * 获取正在运行的守护进程端口
     */
    @JavascriptInterface
    fun getDaemonPort(): Int {
        return daemonPort
    }

    /**
     * 获取常见公共目录推荐路径
     */
    @JavascriptInterface
    fun getCommonDirectories(): String {
        val obj = JSONObject()
        obj.put("camera", Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DCIM).absolutePath + "/Camera")
        obj.put("pictures", Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_PICTURES).absolutePath)
        obj.put("documents", Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOCUMENTS).absolutePath)
        obj.put("downloads", Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS).absolutePath)
        return obj.toString()
    }
}
