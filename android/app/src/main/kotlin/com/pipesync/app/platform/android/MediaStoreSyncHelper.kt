package com.pipesync.app.platform.android

import android.content.Context
import android.media.MediaScannerConnection
import android.provider.MediaStore
import android.util.Log

/**
 * Android 原生端媒体库同步实现
 * 消除物理删除后的“幽灵缩略图” (Section 5.1 MediaStore Dirty Cache Elimination)
 */
object MediaStoreSyncHelper {
    private const val TAG = "MediaStoreSyncHelper"

    @JvmStatic
    fun cleanUpMediaStore(context: Context, targetPath: String) {
        try {
            val fileUri = MediaStore.Files.getContentUri("external")
            // 步骤 1: 精准清除 MediaStore 对应行记录
            val rowsDeleted = context.contentResolver.delete(
                fileUri,
                "${MediaStore.MediaColumns.DATA} = ?",
                arrayOf(targetPath)
            )
            Log.d(TAG, "MediaStore cleanup for $targetPath: deleted rows = $rowsDeleted")

            // 步骤 2: 若数据库未能精准删除，显式驱动扫描连接器进行核对剥离
            if (rowsDeleted == 0) {
                MediaScannerConnection.scanFile(
                    context,
                    arrayOf(targetPath),
                    null
                ) { path, uri ->
                    Log.d(TAG, "MediaScanner re-scanned: path=$path, uri=$uri")
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to clean MediaStore for $targetPath: ${e.message}", e)
        }
    }
}
