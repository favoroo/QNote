package com.appone.qnote_flutter

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.widget.RemoteViews

/**
 * 「问小Q」桌面入口组件：整卡一个点击热区，直接打开 App 的 AI 页。
 *
 * 刻意不读任何业务数据，因此 updatePeriodMillis 设为 0（关掉系统周期刷新）、
 * MainActivity.updateAllWidgets 也不广播它——没有数据可刷，多唤醒一次只是耗电。
 */
class AiEntryWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(context: Context, appWidgetManager: AppWidgetManager, appWidgetIds: IntArray) {
        for (appWidgetId in appWidgetIds) {
            updateAppWidget(context, appWidgetManager, appWidgetId)
        }
    }

    private fun updateAppWidget(context: Context, appWidgetManager: AppWidgetManager, appWidgetId: Int) {
        val views = RemoteViews(context.packageName, R.layout.widget_ai_entry)
        views.setOnClickPendingIntent(
            R.id.widget_ai_entry_root,
            WidgetIntents.route(context, "/ai", appWidgetId + 900)
        )
        appWidgetManager.updateAppWidget(appWidgetId, views)
    }
}
