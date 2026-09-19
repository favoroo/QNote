package com.appone.qnote_flutter

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri

/** 小组件跳往 Flutter 页面的 PendingIntent 构造，各组件共用。 */
object WidgetIntents {

    /**
     * 按路由生成跳转 Intent。[path] 支持查询参数，如 `/todo?add=1`、`/ai`，
     * 由 MainActivity 转成 `navigate` 调用或冷启动挂起路由，最终交给 go_router。
     *
     * 关键点是把 route 编进了 data：PendingIntent 判等只比较 action/data/type/class/
     * categories，**不比较 extras**。本 App 的跳转 Intent 全是裸 `Intent(MainActivity)`，
     * 只靠 requestCode 区分，一旦两个组件实例的 requestCode 算出同一个值（例如待办的
     * `appWidgetId + 600` 与新组件的 `widgetId + 900` 恰好相差 300），后注册的会静默
     * 覆盖前一个的 route，表现为「点加号却进了别的页」。
     */
    fun route(context: Context, path: String, requestCode: Int): PendingIntent {
        val intent = Intent(context, MainActivity::class.java).apply {
            data = Uri.parse("qnote://route/${Uri.encode(path)}")
            putExtra("route", path)
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        return PendingIntent.getActivity(
            context,
            requestCode,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }
}
