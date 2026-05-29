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
                context.startActivity(startAppIntent)
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
                
                // 强制触发 ListView 的 Factory 重新拉取数据
                appWidgetManager.notifyAppWidgetViewDataChanged(appWidgetIds, R.id.todo_list_view)
                
                // 重新渲染各个 Widget 实例（更新计数及绑定）
                for (widgetId in appWidgetIds) {
                    updateAppWidget(context, appWidgetManager, widgetId)
                }
            }
        }
    }

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

            // 4. 发送刷新通知广播，重新加载待办列表
            val appWidgetManager = AppWidgetManager.getInstance(context)
            val component = ComponentName(context, TodoWidgetProvider::class.java)
            val appWidgetIds = appWidgetManager.getAppWidgetIds(component)
            appWidgetManager.notifyAppWidgetViewDataChanged(appWidgetIds, R.id.todo_list_view)
            
            // 同时更新头部计数
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

        // 1. 设置待办列表 Service 适配器
        val serviceIntent = Intent(context, TodoWidgetService::class.java).apply {
            putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, appWidgetId)
            data = Uri.parse("qnote://widget/todo/$appWidgetId")
            setPackage(context.packageName)
        }
        @Suppress("DEPRECATION")
        views.setRemoteAdapter(R.id.todo_list_view, serviceIntent)
        views.setEmptyView(R.id.todo_list_view, R.id.todo_empty_view)

        // 2. 设置待办头部刷新点击 -> 发送刷新广播
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

        // 3. 设置待办项点击 BroadCast PendingIntent 模板 (不预设 action 以便 fillInIntent 能够填充自定义 action)
        val listClickIntent = Intent(context, TodoWidgetProvider::class.java)
        val listClickPendingIntent = PendingIntent.getBroadcast(
            context,
            appWidgetId + 200,
            listClickIntent,
            PendingIntent.FLAG_MUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        views.setPendingIntentTemplate(R.id.todo_list_view, listClickPendingIntent)

        // 4. 加载头部未完成计数
        var pendingCount = 0
        var db: SQLiteDatabase? = null
        try {
            val dbFile = context.getDatabasePath("qnote.db")
            if (dbFile.exists()) {
                db = SQLiteDatabase.openDatabase(dbFile.absolutePath, null, SQLiteDatabase.OPEN_READONLY)
                val cursor = db.rawQuery("SELECT COUNT(*) FROM todos WHERE is_deleted = 0 AND is_completed = 0 AND is_long_term = 0", null)
                if (cursor.moveToFirst()) {
                    pendingCount = cursor.getInt(0)
                }
                cursor.close()
            }
        } catch (e: Exception) {
            e.printStackTrace()
        } finally {
            db?.close()
        }
        views.setTextViewText(R.id.todo_widget_count, "($pendingCount)")

        appWidgetManager.updateAppWidget(appWidgetId, views)
        
        // 5. 绑定完适配器后立即强制通知数据源触发拉取一次，防止部分 Launcher 在首次加载时静默而导致列表显示空
        appWidgetManager.notifyAppWidgetViewDataChanged(appWidgetId, R.id.todo_list_view)

        // 6. 延迟 500ms 再次触发一次通知，确保 Launcher 在应用布局并建立 Adapter 后能万无一失地加载出数据
        android.os.Handler(context.mainLooper).postDelayed({
            try {
                AppWidgetManager.getInstance(context).notifyAppWidgetViewDataChanged(appWidgetId, R.id.todo_list_view)
            } catch (e: Exception) {
                e.printStackTrace()
            }
        }, 500)
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
