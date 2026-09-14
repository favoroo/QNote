package com.appone.qnote_flutter

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import android.widget.RemoteViews

class QuickRecordWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(context: Context, appWidgetManager: AppWidgetManager, appWidgetIds: IntArray) {
        for (appWidgetId in appWidgetIds) {
            updateAppWidget(context, appWidgetManager, appWidgetId)
        }
    }

    private fun updateAppWidget(context: Context, appWidgetManager: AppWidgetManager, appWidgetId: Int) {
        val views = RemoteViews(context.packageName, R.layout.widget_quick_record)

        // 点击整个背景和空白区域（包含卡片外部透明区域）
        views.setOnClickPendingIntent(
            R.id.widget_quick_record_root,
            getPendingIntentForAction(context, "input", appWidgetId)
        )

        // 点击输入框区域
        views.setOnClickPendingIntent(
            R.id.btn_input_target,
            getPendingIntentForAction(context, "input", appWidgetId)
        )

        // 点击相册按钮
        views.setOnClickPendingIntent(
            R.id.btn_widget_photo,
            getPendingIntentForAction(context, "photo", appWidgetId)
        )

        // 点击相机按钮
        views.setOnClickPendingIntent(
            R.id.btn_widget_camera,
            getPendingIntentForAction(context, "camera", appWidgetId)
        )

        // 点击发送按钮 (直接呼起对话框并聚焦)
        views.setOnClickPendingIntent(
            R.id.btn_widget_send,
            getPendingIntentForAction(context, "input", appWidgetId)
        )

        appWidgetManager.updateAppWidget(appWidgetId, views)
    }

    private fun getPendingIntentForAction(context: Context, actionType: String, widgetId: Int): PendingIntent {
        val intent = Intent(context, QuickRecordActivity::class.java).apply {
            putExtra("click_action", actionType)
            putExtra("widget_id", widgetId)
            // 确保每次产生的 PendingIntent 包含不同的 extra
            action = "com.appone.qnote_flutter.ACTION_QUICK_RECORD_$actionType"
        }
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        return PendingIntent.getActivity(context, widgetId + actionType.hashCode(), intent, flags)
    }
}
