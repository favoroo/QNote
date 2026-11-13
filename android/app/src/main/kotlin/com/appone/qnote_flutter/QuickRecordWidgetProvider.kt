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
 * 组件不再只有一条 4×1 横条：用户可以把格子缩到 1×1、拉成 1×2 或 2×4。
 * RemoteViews 不能做自适应布局，所以这里读取 launcher 给出的 dp 尺寸，
 * 切换四套布局：
 * - 1×1              → 纯主色笔按钮（button）
 * - 1 行高的横条       → 徽标 + 标题（compact）或完整输入条（wide）
 * - 窄竖卡（1×2～2×4） → 徽标 + 标题，空间够时再露出输入区与操作钮（tall）
 * - 3×2 及以上        → 迷你记录卡（card）
 *
 * 每次 onUpdate / onAppWidgetOptionsChanged 都重新发 RemoteViews：布局和
 * 文案（窄卡标题缩成「记录」）都按当前尺寸重算，避免拉伸后留下上一次的排版。
 */
class QuickRecordWidgetProvider : AppWidgetProvider() {

    companion object {
        // 布局切换阈值（dp）。尺寸来自 AppWidgetManager 的 min/max 宽高，见 widgetSize()。
        private const val BUTTON_MAX = 100
        private const val ONE_ROW_MAX = 100
        private const val WIDE_MIN = 240
        private const val CARD_MIN_WIDTH = 150
        private const val TALL_SUBTITLE_MIN_HEIGHT = 140
        private const val TALL_ACTIONS_ROW_MIN_HEIGHT = 120
        private const val TALL_ACTIONS_COL_MIN_HEIGHT = 170
        private const val TALL_INPUT_MIN_HEIGHT = 180
        private const val CARD_SUBTITLE_MIN_HEIGHT = 140
        private const val CARD_INPUT_MIN_HEIGHT = 155
        private const val CARD_HINT_MIN_HEIGHT = 170
        private const val CARD_WATERMARK_MIN_HEIGHT = 180
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

        // 四个布局的根 id 一致：点卡片任意空白都打开输入弹窗。
        views.setOnClickPendingIntent(R.id.widget_quick_record_root, pendingIntent(context, "input", appWidgetId))

        when (layout) {
            R.layout.widget_quick_record -> bindWide(views, context, appWidgetId)
            R.layout.widget_quick_record_compact -> bindCompact(views, context, appWidgetId, size.first)
            R.layout.widget_quick_record_tall -> bindTall(views, context, appWidgetId, size.first, size.second)
            R.layout.widget_quick_record_card -> bindCard(views, context, appWidgetId, size.first, size.second)
            // button 形态只有一个根点击热区，无需额外绑定
        }

        appWidgetManager.updateAppWidget(appWidgetId, views)
    }

    private fun pickLayout(width: Int, height: Int): Int = when {
        // 1×1：整格按钮。高度先判断，避免 1×2 被误判成按钮
        width < BUTTON_MAX && height < BUTTON_MAX -> R.layout.widget_quick_record_button
        // 高度不足一行、且横向不比高度窄：横条。宽 240dp+ 才放得下输入框和三颗操作钮
        height < ONE_ROW_MAX && width >= height ->
            if (width >= WIDE_MIN) R.layout.widget_quick_record else R.layout.widget_quick_record_compact
        // 窄格（1×2、2×2、2×4）：竖卡；宽度够的矮卡 / 大格走大卡
        width < CARD_MIN_WIDTH -> R.layout.widget_quick_record_tall
        else -> R.layout.widget_quick_record_card
    }

    private fun bindWide(views: RemoteViews, context: Context, appWidgetId: Int) {
        views.setOnClickPendingIntent(R.id.btn_input_target, pendingIntent(context, "input", appWidgetId))
        views.setOnClickPendingIntent(R.id.btn_widget_photo, pendingIntent(context, "photo", appWidgetId))
        views.setOnClickPendingIntent(R.id.btn_widget_camera, pendingIntent(context, "camera", appWidgetId))
        views.setOnClickPendingIntent(R.id.btn_widget_send, pendingIntent(context, "input", appWidgetId))
    }

    private fun bindCompact(views: RemoteViews, context: Context, appWidgetId: Int, width: Int) {
        // 2 格宽只有约 50dp 留给文字，缩成「记录」；3 格宽起再显示完整标题。
        views.setTextViewText(R.id.qr_compact_title, if (width < 130) "记录" else "快速记录")
        // 2 格宽塞两颗图形会挤掉标题；3 格宽起才给相机快捷入口。
        views.setViewVisibility(
            R.id.qr_compact_camera,
            if (width >= 150) View.VISIBLE else View.GONE
        )
        views.setOnClickPendingIntent(R.id.qr_compact_camera, pendingIntent(context, "camera", appWidgetId))
    }

    private fun bindTall(
        views: RemoteViews,
        context: Context,
        appWidgetId: Int,
        width: Int,
        height: Int
    ) {
        val narrow = width < BUTTON_MAX
        views.setTextViewText(R.id.qr_tall_title, if (narrow) "记录" else "快速记录")
        views.setTextViewText(R.id.qr_tall_subtitle, if (narrow) "点按" else "点按开始记录")
        views.setTextViewText(R.id.qr_tall_placeholder, if (narrow) "记录…" else "写点什么…")

        views.setViewVisibility(
            R.id.qr_tall_subtitle,
            if (height >= TALL_SUBTITLE_MIN_HEIGHT) View.VISIBLE else View.GONE
        )

        // 横排两颗 34dp 钮在 2×2 的高度就能放下；1 格宽只能竖排，需要更高才不挤。
        val showRow = !narrow && height >= TALL_ACTIONS_ROW_MIN_HEIGHT
        val showCol = narrow && height >= TALL_ACTIONS_COL_MIN_HEIGHT
        views.setViewVisibility(R.id.qr_tall_actions_row, if (showRow) View.VISIBLE else View.GONE)
        views.setViewVisibility(R.id.qr_tall_actions_col, if (showCol) View.VISIBLE else View.GONE)

        // 1 格宽只有约 40dp 可用宽，放不下可读的输入提示；窄卡只保留标题和操作钮。
        val showInput = !narrow && height >= TALL_INPUT_MIN_HEIGHT
        views.setViewVisibility(R.id.qr_tall_input, if (showInput) View.VISIBLE else View.GONE)
        // 只有输入区够高时才放水印，40dp 的细条里塞 44dp 图标会被裁掉一半。
        views.setViewVisibility(
            R.id.qr_tall_watermark,
            if (showInput && height >= 230) View.VISIBLE else View.GONE
        )
        views.setOnClickPendingIntent(R.id.qr_tall_input, pendingIntent(context, "input", appWidgetId))

        // 横排、竖排两颗按钮都绑一遍：只有可见的那颗会收到点击，隐藏那颗无副作用。
        views.setOnClickPendingIntent(R.id.qr_tall_photo_row, pendingIntent(context, "photo", appWidgetId))
        views.setOnClickPendingIntent(R.id.qr_tall_camera_row, pendingIntent(context, "camera", appWidgetId))
        views.setOnClickPendingIntent(R.id.qr_tall_photo_col, pendingIntent(context, "photo", appWidgetId))
        views.setOnClickPendingIntent(R.id.qr_tall_camera_col, pendingIntent(context, "camera", appWidgetId))
    }

    private fun bindCard(
        views: RemoteViews,
        context: Context,
        appWidgetId: Int,
        width: Int,
        height: Int
    ) {
        views.setTextViewText(
            R.id.qr_card_placeholder,
            if (width < 190) "记下此刻…" else "记录此刻的想法…"
        )

        // 3×2 的空高只有 40dp 上下：先保证底部操作钮放得下，占位文字/副标题按高度逐步露出。
        val showInput = height >= CARD_INPUT_MIN_HEIGHT
        views.setViewVisibility(R.id.qr_card_input, if (showInput) View.VISIBLE else View.GONE)
        views.setViewVisibility(
            R.id.qr_card_short_actions,
            if (showInput) View.GONE else View.VISIBLE
        )
        views.setViewVisibility(
            R.id.qr_card_subtitle,
            if (height >= CARD_SUBTITLE_MIN_HEIGHT) View.VISIBLE else View.GONE
        )
        views.setViewVisibility(
            R.id.qr_card_text_group,
            if (showInput && height >= CARD_SUBTITLE_MIN_HEIGHT) View.VISIBLE else View.GONE
        )
        views.setViewVisibility(
            R.id.qr_card_hint,
            if (showInput && height >= CARD_HINT_MIN_HEIGHT) View.VISIBLE else View.GONE
        )
        views.setViewVisibility(
            R.id.qr_card_watermark,
            if (showInput && height >= CARD_WATERMARK_MIN_HEIGHT) View.VISIBLE else View.GONE
        )

        views.setOnClickPendingIntent(R.id.qr_card_input, pendingIntent(context, "input", appWidgetId))
        views.setOnClickPendingIntent(R.id.qr_card_photo, pendingIntent(context, "photo", appWidgetId))
        views.setOnClickPendingIntent(R.id.qr_card_camera, pendingIntent(context, "camera", appWidgetId))
        views.setOnClickPendingIntent(R.id.qr_card_send, pendingIntent(context, "input", appWidgetId))
        views.setOnClickPendingIntent(R.id.qr_card_photo_short, pendingIntent(context, "photo", appWidgetId))
        views.setOnClickPendingIntent(R.id.qr_card_camera_short, pendingIntent(context, "camera", appWidgetId))
        views.setOnClickPendingIntent(R.id.qr_card_send_short, pendingIntent(context, "input", appWidgetId))
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