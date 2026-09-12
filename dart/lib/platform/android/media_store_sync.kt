package com.pipesync.app.platform.android

import android.content.Context
import android.media.MediaScannerConnection
import android.provider.MediaStore

/**
 * Android 原生端媒体库同步实现
 * 消除物理删除后的“幽灵缩略图”
 */
object MediaStoreSyncHelper {
    @JvmStatic
    fun cleanUpMediaStore(context: Context, targetPath: String) {
        val fileUri = MediaStore.Files.getContentUri("external")
        // 步骤 1: 精准清除 MediaStore 对应行记录
        val rowsDeleted = context.contentResolver.delete(
            fileUri,
            "${MediaStore.MediaColumns.DATA} = ?",
            arrayOf(targetPath)
        )

        // 步骤 2: 若数据库未能精准删除，显式驱动扫描连接器
        if (rowsDeleted == 0) {
            MediaScannerConnection.scanFile(
                context,
                arrayOf(targetPath),
                null
            ) { _, _ ->
                // 底层物理文件缺失状态下，扫描器会自动剥离脏条目
            }
        }
    }
}
