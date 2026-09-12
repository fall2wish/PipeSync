package com.pipesync.app.daemon

import android.content.Context
import android.os.Build
import android.os.Environment
import android.util.Log
import com.pipesync.app.platform.android.MediaStoreSyncHelper
import java.io.*
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.URLDecoder
import java.security.MessageDigest
import kotlin.concurrent.thread
import org.json.JSONArray
import org.json.JSONObject

/**
 * PipeSync 核心引擎守护进程管理器
 * 在 Android 宿主中启动轻量级嵌入式 HTTP 守护服务 (端口 8384)
 * 支撑 Syncthing 风格内嵌 WebKit 管理控制台与局域网 Desktop Pull 2PC 双向数据传输
 */
object NativeDaemonManager {
    private const val TAG = "NativeDaemonManager"
    const val DEFAULT_PORT = 8384

    @Volatile private var isEngineRunning = false
    private var serverSocket: ServerSocket? = null
    private val foldersList = mutableListOf<JSONObject>()
    private val devicesList = mutableListOf<JSONObject>()
    private val taskList = mutableListOf<JSONObject>()
    private val startTime = System.currentTimeMillis()

    fun startDaemon(context: Context, onReady: (port: Int) -> Unit) {
        if (isEngineRunning) {
            onReady(DEFAULT_PORT)
            return
        }

        thread(name = "PipeSync-HttpDaemon", isDaemon = true) {
            try {
                loadNativeLibraries(context)
                initDefaultConfig()

                serverSocket = ServerSocket().apply {
                    reuseAddress = true
                    bind(InetSocketAddress("0.0.0.0", DEFAULT_PORT))
                }
                isEngineRunning = true
                Log.i(TAG, "PipeSync embedded HTTP daemon successfully bound to 0.0.0.0:$DEFAULT_PORT")
                onReady(DEFAULT_PORT)

                while (isEngineRunning && serverSocket?.isClosed == false) {
                    try {
                        val client = serverSocket!!.accept()
                        thread(name = "PipeSync-Worker", isDaemon = true) {
                            handleClient(context, client)
                        }
                    } catch (e: Exception) {
                        if (!isEngineRunning) break
                    }
                }
            } catch (e: Exception) {
                Log.e(TAG, "Failed to bind daemon on $DEFAULT_PORT: ${e.message}", e)
                onReady(DEFAULT_PORT)
            }
        }
    }

    private fun initDefaultConfig() {
        synchronized(foldersList) {
            if (foldersList.isEmpty()) {
                val browserDir = File("/sdcard/Browser")
                var browserCount = 0
                var browserBytes = 0L
                if (browserDir.exists() && browserDir.isDirectory) {
                    browserDir.listFiles()?.filter { it.isFile }?.forEach {
                        browserCount++
                        browserBytes += it.length()
                    }
                }

                foldersList.add(JSONObject().apply {
                    put("id", "folder_browser")
                    put("label", "Browser 文件同步目录")
                    put("path", "/sdcard/Browser")
                    put("mode", "2pc_purge")
                    put("remoteTarget", "F:\\bak\\phone\\Browser")
                    put("plugin", "org.pipesync.media-cleaner")
                    put("isPaused", false)
                    put("autoWatch", true)
                    put("scanIntervalSec", 60)
                    put("fileCount", browserCount)
                    put("totalBytes", browserBytes)
                    put("status", "idle")
                })
            }
        }

        synchronized(devicesList) {
            if (devicesList.isEmpty()) {
                devicesList.add(JSONObject().apply {
                    put("id", "local_this")
                    put("name", "本机 (OnePlus/OPPO PKX110)")
                    put("protocol", "local")
                    put("address", "127.0.0.1:$DEFAULT_PORT")
                    put("isLocal", true)
                    put("connected", true)
                    put("lastSeen", "刚刚")
                })
                devicesList.add(JSONObject().apply {
                    put("id", "device_pc")
                    put("name", "Windows 客户端 (PC)")
                    put("protocol", "desktop_pull")
                    put("address", "F:\\bak\\phone\\Browser")
                    put("isLocal", false)
                    put("connected", true)
                    put("lastSeen", "活跃")
                })
            }
        }
    }

    private fun handleClient(context: Context, socket: Socket) {
        try {
            socket.soTimeout = 10000
            val input = socket.getInputStream()
            val reader = BufferedReader(InputStreamReader(input, Charsets.UTF_8))
            val output = socket.getOutputStream()

            val requestLine = reader.readLine() ?: return
            val parts = requestLine.split(" ")
            if (parts.size < 2) return

            val method = parts[0].uppercase()
            val uri = parts[1]
            val path = if (uri.contains("?")) uri.substringBefore("?") else uri
            val queryString = if (uri.contains("?")) uri.substringAfter("?") else ""
            val queryParams = parseQueryParams(queryString)

            // Read headers
            var line: String?
            var contentLength = 0
            while (reader.readLine().also { line = it } != null) {
                if (line.isNullOrEmpty()) break
                if (line!!.startsWith("Content-Length:", ignoreCase = true)) {
                    contentLength = line!!.substringAfter(":").trim().toIntOrNull() ?: 0
                }
            }

            // Read body if POST
            var body = ""
            if (contentLength > 0) {
                val sb = StringBuilder()
                val buffer = CharArray(2048)
                var bytesRead = 0
                while (bytesRead < contentLength) {
                    val r = reader.read(buffer, 0, Math.min(buffer.size, contentLength - bytesRead))
                    if (r <= 0) break
                    sb.append(buffer, 0, r)
                    bytesRead += String(buffer, 0, r).toByteArray(Charsets.UTF_8).size
                }
                body = sb.toString()
            }

            // Route handling
            when {
                // 1. Web Console GUI
                (method == "GET" && (path == "/" || path == "/index.html")) -> {
                    serveHtmlConsole(context, output)
                }

                // 2. System Status API
                (method == "GET" && (path == "/api/v1/status" || path == "/api/v1/system/status")) -> {
                    val uptimeSec = (System.currentTimeMillis() - startTime) / 1000
                    val json = JSONObject().apply {
                        put("nodeId", "PIPESYNC-ANDROID-PKX110-8384")
                        put("platform", "android")
                        put("model", "${Build.MANUFACTURER} ${Build.MODEL}")
                        put("isSyncing", false)
                        put("totalBytesSynced", 6609940)
                        put("purgedCount", 6)
                        put("totalPurgedCount", 6)
                        put("bandwidth", "0 B/s / 0 B/s")
                        put("uptime", "${uptimeSec / 60}m ${uptimeSec % 60}s")
                        put("isAllFilesGranted", Environment.isExternalStorageManager())
                    }
                    sendJsonResponse(output, 200, json.toString())
                }

                // 3. Synced Folders API
                (method == "GET" && path == "/api/v1/folders") -> {
                    refreshFolderStats()
                    val arr = JSONArray()
                    synchronized(foldersList) {
                        for (f in foldersList) arr.put(f)
                    }
                    sendJsonResponse(output, 200, arr.toString())
                }

                (method == "POST" && path == "/api/v1/folders") -> {
                    try {
                        val obj = JSONObject(body)
                        synchronized(foldersList) {
                            foldersList.add(obj)
                        }
                        sendJsonResponse(output, 200, """{"success":true}""")
                    } catch (e: Exception) {
                        sendJsonResponse(output, 400, """{"error":"${e.message}"}""")
                    }
                }

                // 4. Remote Devices API
                (method == "GET" && path == "/api/v1/devices") -> {
                    val arr = JSONArray()
                    synchronized(devicesList) {
                        for (d in devicesList) arr.put(d)
                    }
                    sendJsonResponse(output, 200, arr.toString())
                }

                // 5. Recent Tasks API
                (method == "GET" && path == "/api/v1/tasks") -> {
                    val arr = JSONArray()
                    synchronized(taskList) {
                        for (t in taskList) arr.put(t)
                    }
                    sendJsonResponse(output, 200, arr.toString())
                }

                // 6. Folder Rescan trigger
                (method == "POST" && path.contains("/rescan")) -> {
                    refreshFolderStats()
                    sendJsonResponse(output, 200, """{"status":"RESCAN_DISPATCHED"}""")
                }

                // 7. Desktop Pull - List files in directory with SHA-256
                (method == "GET" && path == "/pull/list") -> {
                    val dirPath = queryParams["dir"] ?: "/sdcard/Browser"
                    val dir = File(dirPath)
                    val filesArr = JSONArray()

                    if (dir.exists() && dir.isDirectory) {
                        dir.listFiles()?.filter { it.isFile && !it.name.startsWith(".") }?.forEach { f ->
                            val sha = computeSha256(f)
                            filesArr.put(JSONObject().apply {
                                put("name", f.name)
                                put("path", f.absolutePath)
                                put("size", f.length())
                                put("sha256", sha)
                                put("modTime", f.lastModified())
                            })
                        }
                    }

                    val resp = JSONObject().apply {
                        put("dir", dirPath)
                        put("files", filesArr)
                    }
                    sendJsonResponse(output, 200, resp.toString())
                }

                // 8. Desktop Pull - Stream file binary
                (method == "GET" && path == "/pull/file") -> {
                    val filePath = queryParams["path"] ?: ""
                    val file = File(filePath)
                    if (file.exists() && file.isFile) {
                        sendFileBinary(output, file)
                    } else {
                        sendError(output, 404, "File Not Found: $filePath")
                    }
                }

                // 9. Desktop Pull - Purge file after 2PC verify
                ((method == "POST" || method == "GET") && path == "/pull/purge") -> {
                    val filePath = queryParams["path"] ?: if (body.isNotEmpty()) {
                        JSONObject(body).optString("path", "")
                    } else ""

                    if (filePath.isNotEmpty()) {
                        val file = File(filePath)
                        val name = file.name
                        val deleted = file.delete()
                        if (deleted) {
                            MediaStoreSyncHelper.cleanUpMediaStore(context, filePath)
                            synchronized(taskList) {
                                taskList.add(0, JSONObject().apply {
                                    put("taskId", "2pc_${System.currentTimeMillis()}")
                                    put("file", name)
                                    put("stage", "COMMITTED")
                                    put("status", "VERIFIED_AND_PURGED")
                                    put("time", "刚刚")
                                })
                            }
                        }
                        sendJsonResponse(output, 200, """{"status":"PURGED","path":"$filePath","deleted":$deleted}""")
                    } else {
                        sendError(output, 400, "Missing path parameter")
                    }
                }

                // 9. Dynamic Web Console Hot-Update Endpoint
                (method == "POST" && path == "/api/v1/web/update") -> {
                    try {
                        val webDir = File(context.filesDir, "web")
                        if (!webDir.exists()) webDir.mkdirs()
                        File(webDir, "index.html").writeText(body, Charsets.UTF_8)
                        sendJsonResponse(output, 200, """{"success":true,"bytes":${body.length}}""")
                    } catch (e: Exception) {
                        sendJsonResponse(output, 500, """{"error":"${e.message}"}""")
                    }
                }

                // 10. Copilot Workspace Inspection (Strict Security Boundary Enforcement)
                (method == "GET" && path == "/api/v1/copilot/workspace-files") -> {
                    val requestedPath = queryParams["path"] ?: ""
                    
                    var isAuthorized = false
                    var matchedFolderLabel = ""
                    synchronized(foldersList) {
                        for (f in foldersList) {
                            val allowedPath = File(f.optString("path")).canonicalPath
                            if (requestedPath.isNotEmpty()) {
                                val target = File(requestedPath).canonicalPath
                                if (target == allowedPath || target.startsWith(allowedPath + File.separator)) {
                                    isAuthorized = true
                                    matchedFolderLabel = f.optString("label")
                                    break
                                }
                            }
                        }
                    }

                    if (!isAuthorized || requestedPath.isEmpty()) {
                        sendJsonResponse(output, 403, """{"error":"Forbidden: Path is outside the authorized sync folders. AI is strictly restricted to designated workspaces."}""")
                    } else {
                        val dir = File(requestedPath)
                        val sampleFiles = JSONArray()
                        if (dir.exists() && dir.isDirectory) {
                            dir.listFiles()?.filter { !it.name.startsWith(".") }?.take(30)?.forEach { f ->
                                sampleFiles.put(JSONObject().apply {
                                    put("name", f.name)
                                    put("size", f.length())
                                    put("ext", if (f.name.contains(".")) "." + f.name.substringAfterLast(".") else "")
                                    put("isDirectory", f.isDirectory)
                                    put("modTime", f.lastModified())
                                })
                            }
                        }
                        val resp = JSONObject().apply {
                            put("workspace", requestedPath)
                            put("folderLabel", matchedFolderLabel)
                            put("authorized", true)
                            put("sampleFiles", sampleFiles)
                        }
                        sendJsonResponse(output, 200, resp.toString())
                    }
                }

                else -> {
                    sendError(output, 404, "Unknown endpoint")
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "Error handling client: ${e.message}")
        } finally {
            try { socket.close() } catch (_: Exception) {}
        }
    }

    private fun refreshFolderStats() {
        synchronized(foldersList) {
            for (f in foldersList) {
                val path = f.optString("path")
                val dir = File(path)
                if (dir.exists() && dir.isDirectory) {
                    val files = dir.listFiles()?.filter { it.isFile } ?: emptyList()
                    f.put("fileCount", files.size)
                    f.put("totalBytes", files.sumOf { it.length() })
                }
            }
        }
    }

    private fun serveHtmlConsole(context: Context, output: OutputStream) {
        val sdcardOverride = File(Environment.getExternalStorageDirectory(), "PipeSync/index.html")
        val overrideFile = File(context.filesDir, "web/index.html")
        val html = try {
            if (sdcardOverride.exists()) {
                sdcardOverride.readText(Charsets.UTF_8)
            } else if (overrideFile.exists()) {
                overrideFile.readText(Charsets.UTF_8)
            } else {
                context.assets.open("web/index.html").bufferedReader().use { it.readText() }
            }
        } catch (e: Exception) {
            "<!DOCTYPE html><html><body><h1>PipeSync Console</h1><p>Running on Android 16</p></body></html>"
        }
        val bytes = html.toByteArray(Charsets.UTF_8)
        val header = "HTTP/1.1 200 OK\r\n" +
                "Content-Type: text/html; charset=utf-8\r\n" +
                "Content-Length: ${bytes.size}\r\n" +
                "Access-Control-Allow-Origin: *\r\n" +
                "Connection: close\r\n\r\n"
        output.write(header.toByteArray(Charsets.UTF_8))
        output.write(bytes)
        output.flush()
    }

    private fun sendJsonResponse(output: OutputStream, code: Int, json: String) {
        val bytes = json.toByteArray(Charsets.UTF_8)
        val header = "HTTP/1.1 $code OK\r\n" +
                "Content-Type: application/json; charset=utf-8\r\n" +
                "Content-Length: ${bytes.size}\r\n" +
                "Access-Control-Allow-Origin: *\r\n" +
                "Connection: close\r\n\r\n"
        output.write(header.toByteArray(Charsets.UTF_8))
        output.write(bytes)
        output.flush()
    }

    private fun sendFileBinary(output: OutputStream, file: File) {
        val header = "HTTP/1.1 200 OK\r\n" +
                "Content-Type: application/octet-stream\r\n" +
                "Content-Length: ${file.length()}\r\n" +
                "Content-Disposition: attachment; filename=\"${file.name}\"\r\n" +
                "Access-Control-Allow-Origin: *\r\n" +
                "Connection: close\r\n\r\n"
        output.write(header.toByteArray(Charsets.UTF_8))

        FileInputStream(file).use { fis ->
            val buf = ByteArray(65536)
            var n: Int
            while (fis.read(buf).also { n = it } != -1) {
                output.write(buf, 0, n)
            }
        }
        output.flush()
    }

    private fun sendError(output: OutputStream, code: Int, msg: String) {
        val json = """{"error":"$msg"}"""
        val bytes = json.toByteArray(Charsets.UTF_8)
        val header = "HTTP/1.1 $code Error\r\n" +
                "Content-Type: application/json\r\n" +
                "Content-Length: ${bytes.size}\r\n" +
                "Access-Control-Allow-Origin: *\r\n" +
                "Connection: close\r\n\r\n"
        output.write(header.toByteArray(Charsets.UTF_8))
        output.write(bytes)
        output.flush()
    }

    private fun computeSha256(file: File): String {
        return try {
            val md = MessageDigest.getInstance("SHA-256")
            FileInputStream(file).use { fis ->
                val buf = ByteArray(65536)
                var n: Int
                while (fis.read(buf).also { n = it } != -1) {
                    md.update(buf, 0, n)
                }
            }
            md.digest().joinToString("") { "%02x".format(it) }
        } catch (e: Exception) {
            ""
        }
    }

    private fun parseQueryParams(query: String): Map<String, String> {
        val map = mutableMapOf<String, String>()
        if (query.isEmpty()) return map
        for (pair in query.split("&")) {
            val idx = pair.indexOf("=")
            if (idx > 0) {
                val key = URLDecoder.decode(pair.substring(0, idx), "UTF-8")
                val value = URLDecoder.decode(pair.substring(idx + 1), "UTF-8")
                map[key] = value
            }
        }
        return map
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
}
