package com.appone.qnote_flutter

import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Intent
import android.os.Bundle
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.appone.qnote_flutter/widgets"
    private val INSTALLER_CHANNEL = "com.appone.qnote_flutter/installer"
    private val SHARE_CHANNEL = "com.appone.qnote_flutter/share"
    private var pendingRoute: String? = null
    private var pendingSharedText: String? = null
    private var methodChannel: MethodChannel? = null
    private var shareChannel: MethodChannel? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        handleIntent(intent)
        // 升级覆盖安装后系统不会自动触发小组件 onUpdate，冷启动时主动刷新一次，
        // 避免旧小组件持有失效的 PendingIntent 导致点击无反应
        updateAllWidgets()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleIntent(intent)
    }

    private fun handleIntent(intent: Intent?) {
        if (intent == null) return

        // 1. 小组件路由跳转
        val route = intent.getStringExtra("route")
        if (route != null) {
            pendingRoute = route
            // Flutter 引擎就绪时，立即推送路由，解决 App 前台时 didChangeAppLifecycleState 不触发的问题
            methodChannel?.invokeMethod("navigate", route)
        }

        // 2. 外部划选文本（PROCESS_TEXT）
        if (Intent.ACTION_PROCESS_TEXT == intent.action && intent.type == "text/plain") {
            val text = intent.getCharSequenceExtra(Intent.EXTRA_PROCESS_TEXT)?.toString()
            if (!text.isNullOrBlank()) {
                handleIncomingText(text)
            }
        }

        // 3. 外部系统分享文本（ACTION_SEND）
        if (Intent.ACTION_SEND == intent.action && intent.type?.startsWith("text/") == true) {
            val text = intent.getStringExtra(Intent.EXTRA_TEXT)
            if (!text.isNullOrBlank()) {
                handleIncomingText(text)
            }
        }
    }

    private fun handleIncomingText(text: String) {
        pendingSharedText = text
        // Flutter 引擎就绪时，主动推送文本
        shareChannel?.invokeMethod("onSharedText", text)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        methodChannel = channel
        
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "updateWidgets" -> {
                    // 通知桌面小组件更新数据
                    updateAllWidgets()
                    result.success(null)
                }
                "getPendingRoute" -> {
                    result.success(pendingRoute)
                    pendingRoute = null
                }
                else -> {
                    result.notImplemented()
                }
            }
        }

        val shareChan = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SHARE_CHANNEL)
        shareChannel = shareChan
        shareChan.setMethodCallHandler { call, result ->
            when (call.method) {
                "getPendingSharedText" -> {
                    result.success(pendingSharedText)
                    pendingSharedText = null
                }
                else -> {
                    result.notImplemented()
                }
            }
        }

        val installerChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, INSTALLER_CHANNEL)
        installerChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "installApk" -> {
                    val filePath = call.argument<String>("filePath")
                    if (filePath.isNullOrEmpty()) {
                        result.error("INVALID_PATH", "APK 文件路径为空", null)
                        return@setMethodCallHandler
                    }
                    try {
                        val file = File(filePath)
                        if (!file.exists()) {
                            result.error("FILE_NOT_FOUND", "APK 文件不存在", null)
                            return@setMethodCallHandler
                        }
                        val uri = FileProvider.getUriForFile(
                            this,
                            "com.appone.qnote.fileprovider",
                            file
                        )
                        val installIntent = Intent(Intent.ACTION_VIEW).apply {
                            setDataAndType(uri, "application/vnd.android.package-archive")
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        }
                        startActivity(installIntent)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("INSTALL_FAILED", e.localizedMessage, null)
                    }
                }
                else -> {
                    result.notImplemented()
                }
            }
        }
    }

    private fun updateAllWidgets() {
        val context = applicationContext
        
        // 刷新日记快捷输入小组件
        val recordIntent = Intent(context, QuickRecordWidgetProvider::class.java).apply {
            action = AppWidgetManager.ACTION_APPWIDGET_UPDATE
        }
        val recordIds = AppWidgetManager.getInstance(context).getAppWidgetIds(
            ComponentName(context, QuickRecordWidgetProvider::class.java)
        )
        recordIntent.putExtra(AppWidgetManager.EXTRA_APPWIDGET_IDS, recordIds)
        context.sendBroadcast(recordIntent)

        // 刷新待办小组件
        val todoIntent = Intent(context, TodoWidgetProvider::class.java).apply {
            action = AppWidgetManager.ACTION_APPWIDGET_UPDATE
        }
        val todoIds = AppWidgetManager.getInstance(context).getAppWidgetIds(
            ComponentName(context, TodoWidgetProvider::class.java)
        )
        todoIntent.putExtra(AppWidgetManager.EXTRA_APPWIDGET_IDS, todoIds)
        context.sendBroadcast(todoIntent)

    }
}
