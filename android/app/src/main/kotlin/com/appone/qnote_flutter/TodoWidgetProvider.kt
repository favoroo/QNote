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
import android.os.Build
import android.widget.RemoteViews
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

class TodoWidgetProvider : AppWidgetProvider() {
    companion object {
        const val ACTION_TODO_TOGGLE = "com.appone.qnote_flutter.TODO_TOGGLE"
        const val ACTION_TODO_CLICK = "com.appone.qnote_flutter.TODO_CLICK"
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
            ACTION_TODO_CLICK -> {
                val route = intent.getStringExtra("route") ?: "/todo"
                val startAppIntent = Intent(context, MainActivity::class.java).apply {
                    putExtra("route", route)
                    flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
                }
                // 使用 PendingIntent 发送，兼容 Android 12+ 后台启动限制
                val pendingIntent = PendingIntent.getActivity(
                    context,
                    0,
                    startAppIntent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                )
                pendingIntent.send()
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
        // 在后台线程异步修改数据库以保持流畅性
        Thread {
            var db: SQLiteDatabase? = null
            try {
                val dbFile = context.getDatabasePath("qnote.db")
                if (!dbFile.exists()) return@Thread

                db = SQLiteDatabase.openDatabase(dbFile.absolutePath, null, SQLiteDatabase.OPEN_READWRITE)
                val newStatus = if (isCompleted) 0 else 1 // 取反
                val nowStr = getISO8601Timestamp()

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
                var sortOrder = 0
                var createdAt = nowStr

                val cursor = db.rawQuery("SELECT * FROM todos WHERE id = ?", arrayOf(todoId))
                if (cursor.moveToFirst()) {
                    title = cursor.getString(cursor.getColumnIndexOrThrow("title"))
                    desc = cursor.getString(cursor.getColumnIndexOrThrow("description")) ?: ""
                    priority = cursor.getString(cursor.getColumnIndexOrThrow("priority")) ?: "normal"
                    dueDate = cursor.getString(cursor.getColumnIndexOrThrow("due_date"))
                    tags = cursor.getString(cursor.getColumnIndexOrThrow("tags")) ?: ""
                    folderId = cursor.getString(cursor.getColumnIndexOrThrow("folder_id"))
                    isLongTerm = cursor.getInt(cursor.getColumnIndexOrThrow("is_long_term"))
                    reminderTime = cursor.getString(cursor.getColumnIndexOrThrow("reminder_time"))
                    deadline = cursor.getString(cursor.getColumnIndexOrThrow("deadline"))
                    sortOrder = cursor.getInt(cursor.getColumnIndexOrThrow("sort_order"))
                    createdAt = cursor.getString(cursor.getColumnIndexOrThrow("created_at"))
                }
                cursor.close()

                // 2. 更新 todos 表
                val values = ContentValues().apply {
                    put("is_completed", newStatus)
                    put("updated_at", nowStr)
                }
                db.update("todos", values, "id = ?", arrayOf(todoId))

                // 3. 构造更新的 JSON 并记录 sync_log 保证与 Flutter toMap() 表现一致
                val dataJson = buildTodoJsonString(
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
                db.insert("sync_log", null, logValues)

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
        }.start()
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
        val addPendingIntent = getPendingRouteIntent(context, "/todo", appWidgetId + 100)
        views.setOnClickPendingIntent(R.id.todo_widget_title, addPendingIntent)

        // 2. 加载待办数据，前 4 条进行静态渲染
        val todos = ArrayList<TodoItemData>()
        var pendingCount = 0
        var db: SQLiteDatabase? = null
        try {
            val dbFile = context.getDatabasePath("qnote.db")
            if (dbFile.exists()) {
                db = SQLiteDatabase.openDatabase(dbFile.absolutePath, null, SQLiteDatabase.OPEN_READONLY)
                val cursor = db.rawQuery(
                    "SELECT id, title, is_completed, priority FROM todos WHERE is_deleted = 0 AND is_completed = 0 AND is_long_term = 0 ORDER BY sort_order ASC, created_at ASC",
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

                // 点击待办项文字直接跳转主应用待办界面
                val titlePendingIntent = getPendingRouteIntent(context, "/todo", appWidgetId * 10 + i + 100)
                views.setOnClickPendingIntent(titleId, titlePendingIntent)
            } else {
                views.setViewVisibility(layoutId, android.view.View.GONE)
            }
        }

        // 4. 手动控制空状态可见性与“更多”提示
        if (pendingCount == 0) {
            views.setViewVisibility(R.id.todo_empty_view, android.view.View.VISIBLE)
            views.setViewVisibility(R.id.todo_more_layout, android.view.View.GONE)
        } else {
            views.setViewVisibility(R.id.todo_empty_view, android.view.View.GONE)
            if (pendingCount > 4) {
                views.setViewVisibility(R.id.todo_more_layout, android.view.View.VISIBLE)
                views.setTextViewText(R.id.todo_more_badge, "+${pendingCount - 4}")
                // 点击提示文本也可以进入应用
                val morePendingIntent = getPendingRouteIntent(context, "/todo", appWidgetId + 500)
                views.setOnClickPendingIntent(R.id.todo_more_layout, morePendingIntent)
            } else {
                views.setViewVisibility(R.id.todo_more_layout, android.view.View.GONE)
            }
        }

        appWidgetManager.updateAppWidget(appWidgetId, views)
    }


    private fun getPendingRouteIntent(context: Context, route: String, requestCode: Int): PendingIntent {
        val intent = Intent(context, MainActivity::class.java).apply {
            putExtra("route", route)
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        return PendingIntent.getActivity(
            context,
            requestCode,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }

    private fun getISO8601Timestamp(): String {
        val df = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS", Locale.US)
        df.timeZone = TimeZone.getDefault()
        return df.format(Date())
    }

    private fun buildTodoJsonString(
        id: String,
        title: String,
        desc: String,
        isCompleted: Boolean,
        priority: String,
        dueDate: String?,
        tags: String,
        folderId: String?,
        isLongTerm: Boolean,
        reminderTime: String?,
        deadline: String?,
        sortOrder: Int,
        createdAt: String,
        updatedAt: String
    ): String {
        val sb = StringBuilder()
        sb.append("{")
        sb.append("\"id\":\"$id\",")
        sb.append("\"title\":\"$title\",")
        sb.append("\"description\":\"$desc\",")
        sb.append("\"is_completed\":${if (isCompleted) 1 else 0},")
        sb.append("\"priority\":\"$priority\",")
        sb.append("\"due_date\":${if (dueDate != null) "\"$dueDate\"" else "null"},")
        sb.append("\"tags\":\"$tags\",")
        sb.append("\"folder_id\":${if (folderId != null) "\"$folderId\"" else "null"},")
        sb.append("\"is_long_term\":${if (isLongTerm) 1 else 0},")
        sb.append("\"reminder_time\":${if (reminderTime != null) "\"$reminderTime\"" else "null"},")
        sb.append("\"deadline\":${if (deadline != null) "\"$deadline\"" else "null"},")
        sb.append("\"sort_order\":$sortOrder,")
        sb.append("\"created_at\":\"$createdAt\",")
        sb.append("\"updated_at\":\"$updatedAt\",")
        sb.append("\"is_deleted\":0")
        sb.append("}")
        return sb.toString()
    }
}
