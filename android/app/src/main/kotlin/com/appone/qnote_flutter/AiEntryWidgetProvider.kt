package com.appone.qnote_flutter

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.os.Bundle
import android.widget.RemoteViews

/**
 * 「问小Q」桌面入口组件：整卡一个点击热区，直接打开 App 的 AI 页。
 *
 * 刻意不读任何业务数据，因此 updatePeriodMillis 设为 0（关掉系统周期刷新）、
 * MainActivity.updateAllWidgets 也不广播它——没有数据可刷，多唤醒一次只是耗电。
 *
 * 外观按当前格数自适应：1×1 圆钮、2×1 横胶囊、1×2 竖胶囊、2×2 完整卡片。
 * 调整尺寸时系统只会回调 [onAppWidgetOptionsChanged]，必须在那里重新挑布局，
 * 否则组件会一直停在添加时的形态。
 */
class AiEntryWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(context: Context, appWidgetManager: AppWidgetManager, appWidgetIds: IntArray) {
        for (appWidgetId in appWidgetIds) {
            updateAppWidget(context, appWidgetManager, appWidgetId)
        }
    }

    override fun onAppWidgetOptionsChanged(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetId: Int,
        newOptions: Bundle,
    ) {
        updateAppWidget(context, appWidgetManager, appWidgetId, newOptions)
    }

    private fun updateAppWidget(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetId: Int,
        options: Bundle = appWidgetManager.getAppWidgetOptions(appWidgetId),
    ) {
        val widthDp = options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH)
        val heightDp = options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT)

        val views = RemoteViews(context.packageName, resolveLayout(widthDp, heightDp))
        views.setOnClickPendingIntent(
            R.id.widget_ai_entry_root,
            WidgetIntents.route(context, "/ai", appWidgetId + 900)
        )
        appWidgetManager.updateAppWidget(appWidgetId, views)
    }

    /** 按当前格数选布局；宽高都过线才是 2×2，只过一边分别走横向/竖向胶囊。 */
    private fun resolveLayout(widthDp: Int, heightDp: Int): Int = when {
        widthDp >= TWO_CELL_MIN_DP && heightDp >= TWO_CELL_MIN_DP -> R.layout.widget_ai_entry_large
        widthDp >= TWO_CELL_MIN_DP -> R.layout.widget_ai_entry_wide
        heightDp >= TWO_CELL_MIN_DP -> R.layout.widget_ai_entry_tall
        else -> R.layout.widget_ai_entry
    }

    companion object {
        /**
         * 1 格最小 40dp、2 格最小 110dp，取 80dp 作为分界。
         * 不用 55dp：部分启动器上报的实际格宽会比官方口径略大，留出余量避免 2 格被误判成 1 格。
         */
        private const val TWO_CELL_MIN_DP = 80
    }
}
