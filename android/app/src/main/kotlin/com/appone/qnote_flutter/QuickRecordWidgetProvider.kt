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
 * - 整个组件就是一块主色，纯色无渐变；外轮廓统一用 radius=999dp 的胶囊 shape，
 *   系统按短边裁切，所以横条是胶囊、1×1 与方块是正圆，不会出现圆角矩形与圆形混用。
 * - 组件里所有按钮容器都是正圆，颜色只有两种：白色实心（主操作）、半透明白（次级）。
 * - 主操作圆本身就是入口，不再额外放一支笔按钮——提示旁边再放笔是重复表达。
 * - 文字固定为「记一下」，只有横条与较高的方块出现，其余尺寸只留图形。
 *
 * RemoteViews 不能自适应，所以按 launcher 给出的 dp 尺寸切换五套布局：
 * - 1×1            → 主色圆 + 白色笔（button）
 * - 1 行高          → 胶囊横条：提示 + 相册 / 相机（bar）
 * - 1 格宽的高格    → 竖向胶囊：主操作圆，够高再向下长出相册 / 相机（tall）
 * - 宽而矮的方块    → 一排圆钮：主操作圆 + 相册 / 相机（wide）
 * - 其余方块        → 胶囊/圆：主操作圆 + 提示 + 操作排（card）
 */
class QuickRecordWidgetProvider : AppWidgetProvider() {

    companion object {
        // 布局切换阈值（dp）。尺寸来自 AppWidgetManager 的 min/max 宽高，见 widgetSize()。
        private const val SMALL_MAX = 100
        private const val ONE_ROW_MAX = 100
        private const val WIDE_MIN_WIDTH = 170
        private const val WIDE_MAX_HEIGHT = 160
        private const val BAR_ACTIONS_MIN_WIDTH = 150
        private const val TALL_ACTIONS_MIN_HEIGHT = 150
        private const val CARD_ACTIONS_MIN_HEIGHT = 110
        private const val CARD_HINT_MIN_HEIGHT = 160
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

        // 所有布局的根 id 一致：点色块任意空白都打开输入弹窗。
        views.setOnClickPendingIntent(R.id.widget_quick_record_root, pendingIntent(context, "input", appWidgetId))

        when (layout) {
            R.layout.widget_quick_record -> bindBar(views, context, appWidgetId, size.first)
            R.layout.widget_quick_record_wide -> bindWide(views, context, appWidgetId, size.first)
            R.layout.widget_quick_record_tall -> bindTall(views, context, appWidgetId, size.second)
            R.layout.widget_quick_record_card -> bindCard(views, context, appWidgetId, size.second)
            // button 形态整格一个热区，无需额外绑定
        }

        appWidgetManager.updateAppWidget(appWidgetId, views)
    }

    private fun pickLayout(width: Int, height: Int): Int = when {
        // 1×1：整格色块 + 笔。高度也要小于一格，避免 1×2 被误判
        width < SMALL_MAX && height < SMALL_MAX -> R.layout.widget_quick_record_button
        // 1 行高且横向更宽：胶囊横条
        height < ONE_ROW_MAX && width >= height -> R.layout.widget_quick_record
        // 1 格宽的高格：竖向胶囊
        width < SMALL_MAX -> R.layout.widget_quick_record_tall
        // 宽而矮的方块（3×2、4×2）：高度不够上下堆叠，改成一排圆钮
        width >= WIDE_MIN_WIDTH && height < WIDE_MAX_HEIGHT -> R.layout.widget_quick_record_wide
        // 其余（2×2、2×3、2×4、3×3、4×3、4×4…）用大色块
        else -> R.layout.widget_quick_record_card
    }

    private fun bindWide(views: RemoteViews, context: Context, appWidgetId: Int, width: Int) {
        views.setOnClickPendingIntent(R.id.qr_wide_primary, pendingIntent(context, "input", appWidgetId))
        views.setOnClickPendingIntent(R.id.qr_wide_photo, pendingIntent(context, "photo", appWidgetId))
        views.setOnClickPendingIntent(R.id.qr_wide_camera, pendingIntent(context, "camera", appWidgetId))

        // 3 列宽只有约 180dp，主操作圆 + 两颗圆钮已经占满；4 列宽才在中间补「记一下」。
        views.setViewVisibility(
            R.id.qr_wide_hint,
            if (width >= 230) View.VISIBLE else View.GONE
        )
    }

    private fun bindBar(views: RemoteViews, context: Context, appWidgetId: Int, width: Int) {
        // 2 列宽只有约 120dp，提示 + 两颗圆钮会互相挤压；3 列宽起才露出快捷按钮。
        val showActions = width >= BAR_ACTIONS_MIN_WIDTH
        views.setViewVisibility(R.id.qr_bar_photo, if (showActions) View.VISIBLE else View.GONE)
        views.setViewVisibility(R.id.qr_bar_camera, if (showActions) View.VISIBLE else View.GONE)
        views.setOnClickPendingIntent(R.id.qr_bar_photo, pendingIntent(context, "photo", appWidgetId))
        views.setOnClickPendingIntent(R.id.qr_bar_camera, pendingIntent(context, "camera", appWidgetId))
    }

    private fun bindTall(views: RemoteViews, context: Context, appWidgetId: Int, height: Int) {
        // 主操作圆是唯一入口：点它、点胶囊任意位置都打开输入弹窗。
        views.setOnClickPendingIntent(R.id.qr_tall_primary, pendingIntent(context, "input", appWidgetId))
        views.setOnClickPendingIntent(R.id.qr_tall_photo, pendingIntent(context, "photo", appWidgetId))
        views.setOnClickPendingIntent(R.id.qr_tall_camera, pendingIntent(context, "camera", appWidgetId))

        // 1×2 只有约 120dp 高，三颗圆叠起来会挤到贴边；够高才露出次级按钮。
        val showActions = height >= TALL_ACTIONS_MIN_HEIGHT
        views.setViewVisibility(R.id.qr_tall_photo, if (showActions) View.VISIBLE else View.GONE)
        views.setViewVisibility(R.id.qr_tall_camera, if (showActions) View.VISIBLE else View.GONE)
    }

    private fun bindCard(views: RemoteViews, context: Context, appWidgetId: Int, height: Int) {
        views.setOnClickPendingIntent(R.id.qr_card_primary, pendingIntent(context, "input", appWidgetId))
        views.setOnClickPendingIntent(R.id.qr_card_photo, pendingIntent(context, "photo", appWidgetId))
        views.setOnClickPendingIntent(R.id.qr_card_camera, pendingIntent(context, "camera", appWidgetId))

        // 2×2 只够「主操作圆 + 一排圆钮」；更高的方块才补一句「记一下」。
        views.setViewVisibility(
            R.id.qr_card_actions,
            if (height >= CARD_ACTIONS_MIN_HEIGHT) View.VISIBLE else View.GONE
        )
        views.setViewVisibility(
            R.id.qr_card_hint,
            if (height >= CARD_HINT_MIN_HEIGHT) View.VISIBLE else View.GONE
        )
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