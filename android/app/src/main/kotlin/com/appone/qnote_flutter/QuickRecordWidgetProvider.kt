package com.appone.qnote_flutter

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.os.Bundle
import android.view.View
import android.widget.RemoteViews

/**
 * 快捷记录桌面组件。
 *
 * 视觉规则（改动前请先读完）：
 * - 极简曜石黑体系：深黑表面 + 1dp 微亮发丝描边，浅/深色壁纸下均保持清晰轮廓。
 * - 纯图标、无文字，所有按钮一律正圆：柔白大圆 = 主操作（记一条），
 *   深炭灰微描边圆 = 相册 / 相机，靠尺寸分级与偏置（左大右双 / 上大下双）建立主次。
 * - 长条形态不再把按钮拉成撑满整条的胶囊，而是让胶囊坞只包住三颗圆钮并整体居中，
 *   两侧留白就是留白，视觉上是悬浮工具条而不是被拉长的色块。
 *
 * RemoteViews 不能自适应，所以按 launcher 给出的 dp 尺寸切换九套布局：
 * - 1×1              → 60dp 黑色正圆 + 柔白笔（button）
 * - 2×1              → 60dp 黑胶囊：46 / 38 / 38dp 三颗紧凑正圆均分（bar_small）
 * - 3~4×1            → 68dp 黑胶囊：56 / 48 / 48dp 三颗正圆均分（bar）
 * - 1 格宽的高格      → 竖胶囊容器：三颗正圆纵向均分（tall）
 * - 2×2              → 28dp 圆角黑卡片：上 84dp 大圆 + 下两颗 52dp 圆（card）
 * - 2×3 / 2×4        → 28dp 圆角黑卡片：上 96dp 大圆 + 下两颗 64dp 圆（panel_narrow）
 * - 3×2              → 28dp 圆角黑卡片：左 112dp 大圆 + 右两颗 64dp 圆（wide_small）
 * - 4×2              → 28dp 圆角黑卡片：左 136dp 大圆 + 右两颗 68dp 圆（wide）
 * - 3×3              → 28dp 圆角黑卡片：左 112dp 大圆 + 右两颗 72dp 圆（panel）
 * - 4×3 / 4×4        → 28dp 圆角黑卡片：左 160dp 大圆 + 右两颗 92dp 圆（panel_large）
 */
class QuickRecordWidgetProvider : AppWidgetProvider() {

    companion object {
        // 布局切换阈值（dp）。尺寸来自 AppWidgetManager 的 min/max 宽高，见 widgetSize()。
        private const val SMALL_MAX = 100
        private const val ONE_ROW_MAX = 100
        private const val BAR_LARGE_MIN_WIDTH = 230
        private const val TALL_ACTIONS_MIN_HEIGHT = 150
        private const val PANEL_MIN_HEIGHT = 240
        private const val PANEL_MIN_WIDTH = 240
        private const val WIDE_LARGE_MIN_WIDTH = 300
        private const val WIDE_MIN_WIDTH = 220
    }

    override fun onUpdate(context: Context, appWidgetManager: AppWidgetManager, appWidgetIds: IntArray) {
        for (appWidgetId in appWidgetIds) {
            updateAppWidget(context, appWidgetManager, appWidgetId)
        }
    }

    /** 用户拖动组件边缘改变大小时回调；必须在这里重新下发，否则 RemoteViews 会停在旧布局。 */
    override fun onAppWidgetOptionsChanged(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetId: Int,
        newOptions: Bundle
    ) {
        updateAppWidget(context, appWidgetManager, appWidgetId, newOptions)
    }

    private fun updateAppWidget(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetId: Int,
        options: Bundle? = null
    ) {
        val size = widgetSize(context, options ?: appWidgetManager.getAppWidgetOptions(appWidgetId))
        val layout = pickLayout(size.first, size.second)
        val views = RemoteViews(context.packageName, layout)

        // 所有布局的根 id 一致：点组件任意空白都打开输入弹窗。
        views.setOnClickPendingIntent(R.id.widget_quick_record_root, pendingIntent(context, "input", appWidgetId))

        when (layout) {
            R.layout.widget_quick_record -> bindBar(views, context, appWidgetId)
            R.layout.widget_quick_record_bar_small -> bindBar(views, context, appWidgetId)
            R.layout.widget_quick_record_wide -> bindWide(views, context, appWidgetId)
            R.layout.widget_quick_record_wide_small -> bindWide(views, context, appWidgetId)
            R.layout.widget_quick_record_panel -> bindPanel(views, context, appWidgetId)
            R.layout.widget_quick_record_panel_large -> bindPanel(views, context, appWidgetId)
            R.layout.widget_quick_record_panel_narrow -> bindPanel(views, context, appWidgetId)
            R.layout.widget_quick_record_tall -> bindTall(views, context, appWidgetId, size.second)
            R.layout.widget_quick_record_card -> bindCard(views, context, appWidgetId)
            // button 形态整格一个热区，无需额外绑定
        }

        appWidgetManager.updateAppWidget(appWidgetId, views)
    }

    private fun pickLayout(width: Int, height: Int): Int = when {
        // 1×1：居中黑圆 + 笔。高度也要小于一格，避免 1×2 被误判
        width < SMALL_MAX && height < SMALL_MAX -> R.layout.widget_quick_record_button
        // 1 行高：2 列用紧凑三圆条，3~4 列用标准三圆条
        height < ONE_ROW_MAX && width >= height ->
            if (width >= BAR_LARGE_MIN_WIDTH) R.layout.widget_quick_record else R.layout.widget_quick_record_bar_small
        // 1 格宽的高格：竖胶囊容器 + 三颗正圆
        width < SMALL_MAX -> R.layout.widget_quick_record_tall
        // 高卡片（2×3、2×4）：纵向大圆 + 双圆
        height >= PANEL_MIN_HEIGHT && width < PANEL_MIN_WIDTH -> R.layout.widget_quick_record_panel_narrow
        // 高卡片（4×3、4×4）：大号「左大圆 + 右双圆」
        height >= PANEL_MIN_HEIGHT && width >= WIDE_LARGE_MIN_WIDTH -> R.layout.widget_quick_record_panel_large
        // 高卡片（3×3）：「左大圆 + 右双圆」标准号
        height >= PANEL_MIN_HEIGHT -> R.layout.widget_quick_record_panel
        // 宽卡片（4×2）：大号「左大圆 + 右双圆」
        width >= WIDE_LARGE_MIN_WIDTH -> R.layout.widget_quick_record_wide
        // 宽卡片（3×2）：标准号「左大圆 + 右双圆」
        width >= WIDE_MIN_WIDTH -> R.layout.widget_quick_record_wide_small
        // 2×2：纵向大圆 + 双圆
        else -> R.layout.widget_quick_record_card
    }

    private fun bindWide(views: RemoteViews, context: Context, appWidgetId: Int) {
        views.setOnClickPendingIntent(R.id.qr_wide_primary, pendingIntent(context, "input", appWidgetId))
        views.setOnClickPendingIntent(R.id.qr_wide_photo, pendingIntent(context, "photo", appWidgetId))
        views.setOnClickPendingIntent(R.id.qr_wide_camera, pendingIntent(context, "camera", appWidgetId))
    }

    private fun bindPanel(views: RemoteViews, context: Context, appWidgetId: Int) {
        views.setOnClickPendingIntent(R.id.qr_panel_primary, pendingIntent(context, "input", appWidgetId))
        views.setOnClickPendingIntent(R.id.qr_panel_photo, pendingIntent(context, "photo", appWidgetId))
        views.setOnClickPendingIntent(R.id.qr_panel_camera, pendingIntent(context, "camera", appWidgetId))
    }

    private fun bindBar(views: RemoteViews, context: Context, appWidgetId: Int) {
        views.setOnClickPendingIntent(R.id.qr_bar_primary, pendingIntent(context, "input", appWidgetId))
        views.setOnClickPendingIntent(R.id.qr_bar_photo, pendingIntent(context, "photo", appWidgetId))
        views.setOnClickPendingIntent(R.id.qr_bar_camera, pendingIntent(context, "camera", appWidgetId))
    }

    private fun bindTall(views: RemoteViews, context: Context, appWidgetId: Int, height: Int) {
        views.setOnClickPendingIntent(R.id.qr_tall_primary, pendingIntent(context, "input", appWidgetId))
        views.setOnClickPendingIntent(R.id.qr_tall_photo, pendingIntent(context, "photo", appWidgetId))
        views.setOnClickPendingIntent(R.id.qr_tall_camera, pendingIntent(context, "camera", appWidgetId))

        // 极矮的竖格（不足 150dp）只留主白圆；够高才露出两颗次级圆。
        val showActions = height >= TALL_ACTIONS_MIN_HEIGHT
        views.setViewVisibility(R.id.qr_tall_photo, if (showActions) View.VISIBLE else View.GONE)
        views.setViewVisibility(R.id.qr_tall_camera, if (showActions) View.VISIBLE else View.GONE)
    }

    private fun bindCard(views: RemoteViews, context: Context, appWidgetId: Int) {
        views.setOnClickPendingIntent(R.id.qr_card_primary, pendingIntent(context, "input", appWidgetId))
        views.setOnClickPendingIntent(R.id.qr_card_photo, pendingIntent(context, "photo", appWidgetId))
        views.setOnClickPendingIntent(R.id.qr_card_camera, pendingIntent(context, "camera", appWidgetId))
    }

    /**
     * 取组件当前大致尺寸（dp）。
     *
     * launcher 给的是「区间」而不是当前值：竖屏时实际宽度取 minWidth、高度取 maxHeight，
     * 横屏反过来。部分老 launcher 只填 min，因此每一步都留了回退。
     */
    private fun widgetSize(context: Context, options: Bundle): Pair<Int, Int> {
        val minWidth = options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH)
        val maxWidth = options.getInt(AppWidgetManager.OPTION_APPWIDGET_MAX_WIDTH)
        val minHeight = options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT)
        val maxHeight = options.getInt(AppWidgetManager.OPTION_APPWIDGET_MAX_HEIGHT)

        val portrait = context.resources.configuration.orientation != Configuration.ORIENTATION_LANDSCAPE
        val primaryWidth = if (portrait) minWidth else maxWidth
        val fallbackWidth = if (portrait) maxWidth else minWidth
        val primaryHeight = if (portrait) maxHeight else minHeight
        val fallbackHeight = if (portrait) minHeight else maxHeight
        val width = primaryWidth.takeIf { it > 0 } ?: fallbackWidth.takeIf { it > 0 } ?: 250
        val height = primaryHeight.takeIf { it > 0 } ?: fallbackHeight.takeIf { it > 0 } ?: 40
        return width to height
    }

    private fun pendingIntent(context: Context, actionType: String, widgetId: Int): PendingIntent {
        val intent = Intent(context, QuickRecordActivity::class.java).apply {
            putExtra("click_action", actionType)
            putExtra("widget_id", widgetId)
            // action 让不同操作 / 不同组件实例的 PendingIntent 彼此不等
            action = "com.appone.qnote_flutter.ACTION_QUICK_RECORD_$actionType"
        }
        val slot = when (actionType) {
            "input" -> 0
            "photo" -> 1
            "camera" -> 2
            else -> 3
        }
        val requestCode = widgetId * 10 + slot
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        return PendingIntent.getActivity(context, requestCode, intent, flags)
    }
}
