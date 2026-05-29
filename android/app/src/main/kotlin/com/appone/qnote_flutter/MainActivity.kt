package com.appone.qnote_flutter

import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.appone.qnote_flutter/widgets"
    private var pendingRoute: String? = null
    private var methodChannel: MethodChannel? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        handleIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleIntent(intent)
    }

    private fun handleIntent(intent: Intent?) {
        val route = intent?.getStringExtra("route")
        if (route != null) {
            val channel = methodChannel
            if (channel != null) {
                channel.invokeMethod("navigate", route)
            } else {
                pendingRoute = route
            }
        }
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
