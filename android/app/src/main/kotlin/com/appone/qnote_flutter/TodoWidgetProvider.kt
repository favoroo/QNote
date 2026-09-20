package com.appone.qnote_flutter

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.database.sqlite.SQLiteDatabase
import android.net.Uri
import android.widget.RemoteViews

class TodoWidgetProvider : AppWidgetProvider() {
    companion object {
        const val ACTION_TODO_TOGGLE = "com.appone.qnote_flutter.TODO_TOGGLE"
        const val ACTION_TODO_REFRESH = "com.appone.qnote_flutter.TODO_REFRESH"
        const val EXTRA_TODO_ID = "extra_todo_id"
        const val EXTRA_TODO_STATUS = "extra_todo_status"
    }

    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)
        when (intent.action) {
            ACTION_TODO_TOGGLE -> {
                val todoId = intent.getStringExtra(EXTRA_TODO_ID)
                val currentStatus = intent.getIntExtra(EXTRA_TODO_STATUS, 0)
                if (todoId != null) {
                    toggleTodoStatus(context, todoId, currentStatus == 1)
                }
            }
            ACTION_TODO_REFRESH -> {
                val appWidgetManager = AppWidgetManager.getInstance(context)
                val targetWidgetId = intent.getIntExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, AppWidgetManager.INVALID_APPWIDGET_ID)
                
                // 弹出 Toast 提示给用户明确的点击反馈
                android.widget.Toast.makeText(context, "今日待办数据已刷新", android.widget.Toast.LENGTH_SHORT).show()

                val appWidgetIds = if (targetWidgetId != AppWidgetManager.INVALID_APPWIDGET_ID) {
                    intArrayOf(targetWidgetId)
                } else {
                    val component = ComponentName(context, TodoWidgetProvider::class.java)
                    appWidgetManager.getAppWidgetIds(component)
                }
                
                // 重新渲染各个 Widget 实例（同步拉取数据并刷新 UI）
                for (widgetId in appWidgetIds) {
                    updateAppWidget(context, appWidgetManager, widgetId)
                }
            }
        }
    }

    data class TodoItemData(
        val id: String,
        val title: String,
        val isCompleted: Boolean,
        val priority: String
    )

    private fun toggleTodoStatus(context: Context, todoId: String, isCompleted: Boolean) {
        // 走串行队列而不是裸 Thread：组件进程被回收时，Thread 会连同这次勾选一起被丢掉
        WidgetDatabase.executor.execute {
            var db: SQLiteDatabase? = null
            try {
                // 用非空局部量接住，避免可空 var 在多层 try 里丢智能转换
                val writable = WidgetDatabase.openReadwrite(context) ?: return@execute
                db = writable

                val newStatus = if (isCompleted) 0 else 1 // 取反
                val nowStr = WidgetDatabase.iso8601()

                // 1. 获取原数据，记录到 sync_log
                var title = ""
                var desc = ""
                var priority = "normal"
                var dueDate: String? = null
                var tags = ""
                var folderId: String? = null
                var isLongTerm = 0
                var reminderTime: String? = null
                var deadline: String? = null
                var repeatRule = "none"
                var sortOrder = 0L
                var createdAt = nowStr

                val cursor = db.rawQuery("SELECT * FROM todos WHERE id = ?", arrayOf(todoId))
                if (!cursor.moveToFirst()) {
                    // 待办已被删除：继续往下写会给一条不存在的记录造出 update 日志，污染增量包
                    cursor.close()
                    return@execute
                }
                title = cursor.getString(cursor.getColumnIndexOrThrow("title"))
                desc = cursor.getString(cursor.getColumnIndexOrThrow("description")) ?: ""
                priority = cursor.getString(cursor.getColumnIndexOrThrow("priority")) ?: "normal"
                dueDate = cursor.getString(cursor.getColumnIndexOrThrow("due_date"))
                tags = cursor.getString(cursor.getColumnIndexOrThrow("tags")) ?: ""
                folderId = cursor.getString(cursor.getColumnIndexOrThrow("folder_id"))
                isLongTerm = cursor.getInt(cursor.getColumnIndexOrThrow("is_long_term"))
                reminderTime = cursor.getString(cursor.getColumnIndexOrThrow("reminder_time"))
                deadline = cursor.getString(cursor.getColumnIndexOrThrow("deadline"))
                // repeat_rule 是后期迁移加的列，老库可能还没有；用 getColumnIndex 容错，
                // 避免整次勾选因为一个字段而抛异常失败
                val repeatRuleIndex = cursor.getColumnIndex("repeat_rule")
                if (repeatRuleIndex >= 0 && !cursor.isNull(repeatRuleIndex)) {
                    repeatRule = cursor.getString(repeatRuleIndex)
                }
                // Long 读取毫秒时间戳，getInt 会截断到 32 位污染 sync_log 与回写值
                sortOrder = cursor.getLong(cursor.getColumnIndexOrThrow("sort_order"))
                createdAt = cursor.getString(cursor.getColumnIndexOrThrow("created_at"))
                cursor.close()

                // 2. 更新 todos 表
                val values = ContentValues().apply {
                    put("is_completed", newStatus)
                    put("updated_at", nowStr)
                }

                // 3. 构造更新的 JSON 并记录 sync_log 保证与 Flutter toMap() 表现一致
                val dataJson = WidgetDatabase.buildTodoJson(
                    id = todoId,
                    title = title,
                    desc = desc,
                    isCompleted = newStatus == 1,
                    priority = priority,
                    dueDate = dueDate,
                    tags = tags,
                    folderId = folderId,
                    isLongTerm = isLongTerm == 1,
                    reminderTime = reminderTime,
                    deadline = deadline,
                    repeatRule = repeatRule,
                    sortOrder = sortOrder,
                    createdAt = createdAt,
                    updatedAt = nowStr
                )

                val logValues = ContentValues().apply {
                    put("table_name", "todos")
                    put("record_id", todoId)
                    put("operation", "update")
                    put("data", dataJson)
                    put("timestamp", nowStr)
                }

                // 三笔写入放同一事务：中途崩溃不会留下「待办已改但无同步日志」或反过来的状态
                db.beginTransaction()
                try {
                    db.update("todos", values, "id = ?", arrayOf(todoId))
                    db.insert("sync_log", null, logValues)
                    // 就地刷新今日计数，桌面立刻反映新值，不必等下一次回 App 由 Dart 覆写
                    WidgetDatabase.writeSnapshotInt(
                        db,
                        WidgetDatabase.SNAPSHOT_TODO_PENDING_TODAY,
                        WidgetDatabase.countTodayPending(db)
                    )
                    db.setTransactionSuccessful()
                } finally {
                    db.endTransaction()
                }
            } catch (e: Exception) {
                e.printStackTrace()
            } finally {
                db?.close()
            }

            // 4. 发送刷新通知广播，重新加载/渲染待办列表
            val appWidgetManager = AppWidgetManager.getInstance(context)
            val component = ComponentName(context, TodoWidgetProvider::class.java)
            val appWidgetIds = appWidgetManager.getAppWidgetIds(component)

            // 重新渲染各个 Widget 实例
            for (widgetId in appWidgetIds) {
                updateAppWidget(context, appWidgetManager, widgetId)
            }
        }
    }

    override fun onUpdate(context: Context, appWidgetManager: AppWidgetManager, appWidgetIds: IntArray) {
        for (appWidgetId in appWidgetIds) {
            updateAppWidget(context, appWidgetManager, appWidgetId)
        }
    }

    private fun updateAppWidget(context: Context, appWidgetManager: AppWidgetManager, appWidgetId: Int) {
        val views = RemoteViews(context.packageName, R.layout.widget_todo)

        // 1. 设置待办头部刷新点击 -> 发送刷新广播
        val refreshIntent = Intent(context, TodoWidgetProvider::class.java).apply {
            action = ACTION_TODO_REFRESH
            putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, appWidgetId)
        }
        val refreshPendingIntent = PendingIntent.getBroadcast(
            context,
            appWidgetId + 300,
            refreshIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        views.setOnClickPendingIntent(R.id.btn_widget_todo_refresh, refreshPendingIntent)

        // 点击标题仍然进入今日待办页
        val addPendingIntent = WidgetIntents.route(context, "/todo", appWidgetId + 100)
        views.setOnClickPendingIntent(R.id.todo_widget_title, addPendingIntent)

        // 点击加号在桌面原地弹出原生快速添加弹窗（QuickTodoAddActivity），不再跳进应用
        val quickAddIntent = Intent(context, QuickTodoAddActivity::class.java)
        val quickAddPendingIntent = PendingIntent.getActivity(
            context,
            appWidgetId + 700,
            quickAddIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        views.setOnClickPendingIntent(R.id.btn_widget_todo_add, quickAddPendingIntent)

        // 2. 加载待办数据，前 4 条进行静态渲染
        val todos = ArrayList<TodoItemData>()
        var pendingCount = 0
        var db: SQLiteDatabase? = null
        try {
            db = WidgetDatabase.openReadonly(context)
            if (db != null) {
                // 计数直接查 todos，不读 widget_snapshot：两者同库同源，快照只可能比表更旧，
                // 读它反而会把桌面数字冻在上次 App 运行的值上。口径一致性靠 TODAY_PENDING_WHERE
                // 与 Dart 侧 WidgetSnapshotService 保持同形，两侧都有测试锁定。
                val cursor = db.rawQuery(
                    "SELECT id, title, is_completed, priority FROM todos WHERE ${WidgetDatabase.TODAY_PENDING_WHERE} " +
                        "ORDER BY sort_order ASC, created_at ASC",
                    null
                )
                pendingCount = cursor.count
                var count = 0
                while (cursor.moveToNext() && count < 4) {
                    val id = cursor.getString(0)
                    val title = cursor.getString(1)
                    val isCompleted = cursor.getInt(2) == 1
                    val priority = cursor.getString(3) ?: "normal"
                    todos.add(TodoItemData(id, title, isCompleted, priority))
                    count++
                }
                cursor.close()
            }
        } catch (e: Exception) {
            e.printStackTrace()
        } finally {
            db?.close()
        }

        // 设置今日待办总数
        views.setTextViewText(R.id.todo_widget_count, "($pendingCount)")

        // 3. 静态渲染槽位定义
        val itemLayouts = intArrayOf(
            R.id.todo_item_layout_0,
            R.id.todo_item_layout_1,
            R.id.todo_item_layout_2,
            R.id.todo_item_layout_3
        )
        val itemTitles = intArrayOf(
            R.id.todo_item_title_0,
            R.id.todo_item_title_1,
            R.id.todo_item_title_2,
            R.id.todo_item_title_3
        )
        val itemCheckboxes = intArrayOf(
            R.id.todo_item_checkbox_0,
            R.id.todo_item_checkbox_1,
            R.id.todo_item_checkbox_2,
            R.id.todo_item_checkbox_3
        )
        val itemPriorities = intArrayOf(
            R.id.todo_item_priority_0,
            R.id.todo_item_priority_1,
            R.id.todo_item_priority_2,
            R.id.todo_item_priority_3
        )

        for (i in 0..3) {
            val layoutId = itemLayouts[i]
            val titleId = itemTitles[i]
            val checkboxId = itemCheckboxes[i]
            val priorityId = itemPriorities[i]

            if (i < todos.size) {
                val todo = todos[i]
                views.setViewVisibility(layoutId, android.view.View.VISIBLE)
                views.setTextViewText(titleId, todo.title)

                // 设置 Checkbox 与完成文本样式
                if (todo.isCompleted) {
                    views.setImageViewResource(checkboxId, R.drawable.ic_checkbox_checked)
                    views.setTextColor(titleId, context.getColor(R.color.widget_text_secondary))
                } else {
                    views.setImageViewResource(checkboxId, R.drawable.ic_checkbox_unchecked)
                    views.setTextColor(titleId, context.getColor(R.color.widget_text_primary))
                }

                // 重要待办标绿点
                if (todo.priority == "important") {
                    views.setViewVisibility(priorityId, android.view.View.VISIBLE)
                } else {
                    views.setViewVisibility(priorityId, android.view.View.GONE)
                }

                // 点击 Checkbox 进行状态切换
                val toggleIntent = Intent(context, TodoWidgetProvider::class.java).apply {
                    action = ACTION_TODO_TOGGLE
                    putExtra(EXTRA_TODO_ID, todo.id)
                    putExtra(EXTRA_TODO_STATUS, if (todo.isCompleted) 1 else 0)
                    data = Uri.parse("qnote://todo/toggle/$appWidgetId/${todo.id}")
                }
                val togglePendingIntent = PendingIntent.getBroadcast(
                    context,
                    appWidgetId * 10 + i,
                    toggleIntent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE
                )
                views.setOnClickPendingIntent(checkboxId, togglePendingIntent)

                // 点击待办项文字直接跳转主应用待办界面：与标题同一目标，复用同一个 PendingIntent，
                // 不必为每个槽位再构造一份
                views.setOnClickPendingIntent(titleId, addPendingIntent)
            } else {
                views.setViewVisibility(layoutId, android.view.View.GONE)
            }
        }

        // 4. 手动控制空状态可见性与“更多”提示
        if (pendingCount == 0) {
            // 隐藏列表容器：它同样占 layout_weight=1，不隐藏会把剩余空间对半分，空态文本只能在下半区居中而偏下
            views.setViewVisibility(R.id.todo_static_container, android.view.View.GONE)
            views.setViewVisibility(R.id.todo_empty_view, android.view.View.VISIBLE)
            views.setViewVisibility(R.id.todo_more_layout, android.view.View.GONE)
        } else {
            views.setViewVisibility(R.id.todo_static_container, android.view.View.VISIBLE)
            views.setViewVisibility(R.id.todo_empty_view, android.view.View.GONE)
            if (pendingCount > 4) {
                views.setViewVisibility(R.id.todo_more_layout, android.view.View.VISIBLE)
                views.setTextViewText(R.id.todo_more_badge, "+${pendingCount - 4}")
                // 点击提示文本也可以进入应用
                views.setOnClickPendingIntent(R.id.todo_more_layout, addPendingIntent)
            } else {
                views.setViewVisibility(R.id.todo_more_layout, android.view.View.GONE)
            }
        }

        appWidgetManager.updateAppWidget(appWidgetId, views)
    }
}
