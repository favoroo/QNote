package com.appone.qnote_flutter

import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Intent
import android.net.Uri
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
    private val USAGE_STATS_CHANNEL = "com.appone.qnote_flutter/usage_stats"
    private var pendingRoute: String? = null
    private var pendingSharedText: String? = null
    private var pendingSharedImages: ArrayList<String>? = null
    private var methodChannel: MethodChannel? = null
    private var shareChannel: MethodChannel? = null
    private var usageStatsHelper: UsageStatsHelper? = null

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

        // 4. 外部系统分享图片（ACTION_SEND 单张 / ACTION_SEND_MULTIPLE 多张）
        if (intent.type?.startsWith("image/") == true) {
            when (intent.action) {
                Intent.ACTION_SEND -> {
                    @Suppress("DEPRECATION")
                    val uri = intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
                    if (uri != null) {
                        handleIncomingImages(listOf(uri))
                    }
                }
                Intent.ACTION_SEND_MULTIPLE -> {
                    @Suppress("DEPRECATION")
                    val uris = intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)
                    if (!uris.isNullOrEmpty()) {
                        handleIncomingImages(uris)
                    }
                }
            }
        }
    }

    private fun handleIncomingText(text: String) {
        pendingSharedText = text
        // Flutter 引擎就绪时主动推送文本；Dart 确认接收后才清空挂起，
        // 避免回前台拉取（getPendingSharedText）把同一份再投递一次，
        // 弹出旧的引用卡片。推送未达（冷启动 Dart 未就绪）则保留给拉取兜底
        shareChannel?.invokeMethod("onSharedText", text, object : MethodChannel.Result {
            override fun success(result: Any?) {
                pendingSharedText = null
            }

            override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {}

            override fun notImplemented() {}
        })
    }

    private fun handleIncomingImages(uris: List<Uri>) {
        // 分享图片为一次性内容：先清掉上次遗留的缓存文件，避免持续占用空间
        val dir = File(cacheDir, "shared_images")
        dir.listFiles()?.forEach { it.delete() }

        val saved = ArrayList<String>()
        for (uri in uris) {
            try {
                val file = copyUriToCache(uri, dir, saved.size) ?: continue
                saved.add(file.absolutePath)
            } catch (_: Exception) {
                // 单张图片读取失败不阻断其余图片
            }
        }
        if (saved.isEmpty()) return

        pendingSharedImages = saved
        // Flutter 引擎就绪时主动推送图片路径列表；Dart 确认接收后才清空挂起，
        // 否则回前台 resumed 拉取（getPendingSharedImages）会拿到同一份再投递一次，
        // 附件条出现重复图片。推送未达（冷启动 Dart 未就绪）则保留给拉取兜底
        shareChannel?.invokeMethod("onSharedImages", saved, object : MethodChannel.Result {
            override fun success(result: Any?) {
                pendingSharedImages = null
            }

            override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {}

            override fun notImplemented() {}
        })
    }

    /** 把 content:// Uri 复制到应用缓存目录，返回落盘文件（分享 Uri 的读权限仅在 Intent 存续期内有效） */
    private fun copyUriToCache(uri: Uri, dir: File, index: Int): File? {
        val mime = contentResolver.getType(uri) ?: "image/jpeg"
        val ext = when (mime) {
            "image/png" -> "png"
            "image/webp" -> "webp"
            "image/gif" -> "gif"
            "image/bmp" -> "bmp"
            else -> "jpg"
        }
        dir.mkdirs()
        val file = File(dir, "share_${System.currentTimeMillis()}_${index}_${(0..999).random()}.$ext")
        val input = contentResolver.openInputStream(uri) ?: return null
        input.use { stream ->
            file.outputStream().use { output ->
                stream.copyTo(output)
            }
        }
        return if (file.length() > 0) file else null
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
                "getPendingSharedImages" -> {
                    result.success(pendingSharedImages)
                    pendingSharedImages = null
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

        // 屏幕与应用使用时长统计通道
        val helper = UsageStatsHelper(this)
        usageStatsHelper = helper
        val usageChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, USAGE_STATS_CHANNEL)
        usageChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "hasPermission" -> {
                    result.success(helper.hasUsagePermission())
                }
                "requestPermission" -> {
                    helper.openUsageSettings()
                    result.success(true)
                }
                "getTodayUsage" -> {
                    try {
                        val limit = call.argument<Int>("limit") ?: 30
                        val calendar = java.util.Calendar.getInstance().apply {
                            set(java.util.Calendar.HOUR_OF_DAY, 0)
                            set(java.util.Calendar.MINUTE, 0)
                            set(java.util.Calendar.SECOND, 0)
                            set(java.util.Calendar.MILLISECOND, 0)
                        }
                        val startTime = calendar.timeInMillis
                        val endTime = System.currentTimeMillis()

                        val appList = helper.getUsageStats(startTime, endTime, limit)
                        val totalTime = helper.calculateTotalScreenTime(startTime, endTime)

                        // 获取昨天全天时长以计算对比差值
                        val yesterdayCal = java.util.Calendar.getInstance().apply {
                            add(java.util.Calendar.DAY_OF_YEAR, -1)
                            set(java.util.Calendar.HOUR_OF_DAY, 0)
                            set(java.util.Calendar.MINUTE, 0)
                            set(java.util.Calendar.SECOND, 0)
                            set(java.util.Calendar.MILLISECOND, 0)
                        }
                        val yesterdayStart = yesterdayCal.timeInMillis
                        yesterdayCal.set(java.util.Calendar.HOUR_OF_DAY, 23)
                        yesterdayCal.set(java.util.Calendar.MINUTE, 59)
                        yesterdayCal.set(java.util.Calendar.SECOND, 59)
                        yesterdayCal.set(java.util.Calendar.MILLISECOND, 999)
                        val yesterdayEnd = yesterdayCal.timeInMillis
                        val yesterdayTotalTime = helper.calculateTotalScreenTime(yesterdayStart, yesterdayEnd)

                        result.success(
                            mapOf(
                                "totalTime" to totalTime,
                                "yesterdayTotalTime" to yesterdayTotalTime,
                                "appList" to appList
                            )
                        )
                    } catch (e: Exception) {
                        result.error("USAGE_QUERY_FAILED", e.localizedMessage, null)
                    }
                }
                "getWeeklyScreenTime" -> {
                    try {
                        val weeklyList = helper.getWeeklyScreenTime()
                        result.success(weeklyList)
                    } catch (e: Exception) {
                        result.error("WEEKLY_QUERY_FAILED", e.localizedMessage, null)
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
