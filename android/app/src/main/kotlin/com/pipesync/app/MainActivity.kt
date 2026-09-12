package com.pipesync.app

import android.annotation.SuppressLint
import android.content.Intent
import android.graphics.Bitmap
import android.net.Uri
import android.os.Bundle
import android.view.View
import android.webkit.ConsoleMessage
import android.webkit.JsResult
import android.webkit.WebChromeClient
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.Button
import android.widget.ProgressBar
import androidx.activity.OnBackPressedCallback
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import com.pipesync.app.bridge.PipeSyncNativeBridge
import com.pipesync.app.daemon.NativeDaemonManager
import com.pipesync.app.platform.android.TransferForegroundService

/**
 * PipeSync Android 宿主主窗口
 * 内嵌 WebKit (WebView) 呈现类似 Syncthing 的控制台界面，并桥接 Android 原生底层硬件与系统服务
 */
class MainActivity : AppCompatActivity() {

    private lateinit var webView: WebView
    private lateinit var loadingProgress: ProgressBar
    private lateinit var errorView: View
    private lateinit var btnRetry: Button
    private var currentPort = NativeDaemonManager.DEFAULT_PORT

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        webView = findViewById(R.id.webView)
        loadingProgress = findViewById(R.id.loadingProgress)
        errorView = findViewById(R.id.errorView)
        btnRetry = findViewById(R.id.btnRetry)

        // 1. 启动 Android 14/15 dataSync 前台保活服务
        TransferForegroundService.start(this)

        // 2. 初始化并配置内嵌 WebKit
        setupWebView()

        // 3. 注册返回键处理（支持网页内历史回退）
        setupBackNavigation()

        // 4. 重试按钮逻辑
        btnRetry.setOnClickListener {
            errorView.visibility = View.GONE
            webView.visibility = View.VISIBLE
            loadConsole()
        }

        // 5. 启动管道守护进程并加载控制台
        NativeDaemonManager.startDaemon(this) { port ->
            currentPort = port
            runOnUiThread {
                loadConsole()
            }
        }
    }

    @SuppressLint("SetJavaScriptEnabled")
    private fun setupWebView() {
        val settings = webView.settings
        settings.javaScriptEnabled = true
        settings.domStorageEnabled = true
        settings.databaseEnabled = true
        settings.allowFileAccess = true
        settings.allowContentAccess = true
        settings.loadWithOverviewMode = true
        settings.useWideViewPort = true
        settings.cacheMode = WebSettings.LOAD_DEFAULT

        // 注入 Android 原生能力桥接层: window.PipeSyncNative
        webView.addJavascriptInterface(PipeSyncNativeBridge(this, currentPort), "PipeSyncNative")

        webView.webChromeClient = object : WebChromeClient() {
            override fun onProgressChanged(view: WebView?, newProgress: Int) {
                if (newProgress < 100) {
                    loadingProgress.visibility = View.VISIBLE
                    loadingProgress.progress = newProgress
                } else {
                    loadingProgress.visibility = View.GONE
                }
            }

            override fun onJsAlert(view: WebView?, url: String?, message: String?, result: JsResult?): Boolean {
                AlertDialog.Builder(this@MainActivity)
                    .setTitle("PipeSync")
                    .setMessage(message)
                    .setPositiveButton("确定") { _, _ -> result?.confirm() }
                    .setOnCancelListener { result?.cancel() }
                    .show()
                return true
            }

            override fun onJsConfirm(view: WebView?, url: String?, message: String?, result: JsResult?): Boolean {
                AlertDialog.Builder(this@MainActivity)
                    .setTitle("PipeSync 确认")
                    .setMessage(message)
                    .setPositiveButton("确定") { _, _ -> result?.confirm() }
                    .setNegativeButton("取消") { _, _ -> result?.cancel() }
                    .setOnCancelListener { result?.cancel() }
                    .show()
                return true
            }

            override fun onConsoleMessage(consoleMessage: ConsoleMessage?): Boolean {
                // 转发前端 JS 日志至 Logcat
                android.util.Log.d("PipeSync-WebKit", "[JS ${consoleMessage?.messageLevel()}] ${consoleMessage?.message()}")
                return true
            }
        }

        webView.webViewClient = object : WebViewClient() {
            override fun onPageStarted(view: WebView?, url: String?, favicon: Bitmap?) {
                errorView.visibility = View.GONE
            }

            override fun onReceivedError(view: WebView?, request: WebResourceRequest?, error: WebResourceError?) {
                if (request?.isForMainFrame == true) {
                    webView.visibility = View.GONE
                    errorView.visibility = View.VISIBLE
                }
            }

            override fun shouldOverrideUrlLoading(view: WebView?, request: WebResourceRequest?): Boolean {
                val url = request?.url?.toString() ?: return false
                // 本地控制台页面在 WebKit 内部加载，外部文档链接调用系统浏览器
                return if (url.startsWith("http://127.0.0.1") || url.startsWith("http://localhost")) {
                    false
                } else {
                    try {
                        startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
                    } catch (_: Exception) {}
                    true
                }
            }
        }
    }

    private fun loadConsole() {
        val url = "http://127.0.0.1:$currentPort/"
        webView.loadUrl(url)
    }

    private fun setupBackNavigation() {
        onBackPressedDispatcher.addCallback(this, object : OnBackPressedCallback(true) {
            override fun handleOnBackPressed() {
                if (webView.canGoBack()) {
                    webView.goBack()
                } else {
                    // 后退退到系统桌面，不销毁后台服务
                    moveTaskToBack(true)
                }
            }
        })
    }

    override fun onDestroy() {
        webView.destroy()
        super.onDestroy()
    }
}
