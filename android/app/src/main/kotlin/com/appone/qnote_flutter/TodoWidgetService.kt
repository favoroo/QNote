package com.appone.qnote_flutter

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.Intent
import android.database.sqlite.SQLiteDatabase
import android.widget.RemoteViews
import android.widget.RemoteViewsService

class TodoWidgetService : RemoteViewsService() {
    override fun onGetViewFactory(intent: Intent): RemoteViewsFactory {
        return TodoViewsFactory(applicationContext, intent)
    }
}

class TodoViewsFactory(private val context: Context, intent: Intent) : RemoteViewsService.RemoteViewsFactory {
    private var todoList = ArrayList<TodoItemData>()
    private val appWidgetId = intent.getIntExtra(
        AppWidgetManager.EXTRA_APPWIDGET_ID,
        AppWidgetManager.INVALID_APPWIDGET_ID
    )

    data class TodoItemData(
        val id: String,
        val title: String,
        val isCompleted: Boolean,
        val priority: String
    )

    override fun onCreate() {}

    override fun onDestroy() {
        todoList.clear()
    }

    override fun getCount(): Int = todoList.size

    override fun onDataSetChanged() {
        todoList.clear()
        var db: SQLiteDatabase? = null
        try {
            val dbFile = context.getDatabasePath("qnote.db")
            if (dbFile.exists()) {
                db = SQLiteDatabase.openDatabase(dbFile.absolutePath, null, SQLiteDatabase.OPEN_READONLY)
                // 获取今日未完成且未删除的待办，按 sort_order ASC, created_at ASC 排序
                val cursor = db.rawQuery(
                    "SELECT id, title, is_completed, priority FROM todos WHERE is_deleted = 0 AND is_completed = 0 AND is_long_term = 0 ORDER BY sort_order ASC, created_at ASC",
                    null
                )
                while (cursor.moveToNext()) {
                    val id = cursor.getString(0)
                    val title = cursor.getString(1)
                    val isCompleted = cursor.getInt(2) == 1
                    val priority = cursor.getString(3) ?: "normal"
                    todoList.add(TodoItemData(id, title, isCompleted, priority))
                }
                cursor.close()
            }
        } catch (e: Exception) {
            e.printStackTrace()
        } finally {
            db?.close()
        }
    }

    override fun getViewAt(position: Int): RemoteViews? {
        if (position >= todoList.size) return null
        val data = todoList[position]

        val views = RemoteViews(context.packageName, R.layout.todo_item_widget)
        views.setTextViewText(R.id.todo_item_title, data.title)

        // 1. 设置 Checkbox 图片与完成状态文本样式
        if (data.isCompleted) {
            views.setImageViewResource(R.id.todo_item_checkbox, R.drawable.ic_checkbox_checked)
            // 灰色删除线字体
            views.setInt(R.id.todo_item_title, "setPaintFlags", 16) // Paint.STRIKE_THRU_TEXT_FLAG = 16
            views.setTextColor(R.id.todo_item_title, context.getColor(R.color.widget_text_secondary))
        } else {
            views.setImageViewResource(R.id.todo_item_checkbox, R.drawable.ic_checkbox_unchecked)
            // 恢复常规字体
            views.setInt(R.id.todo_item_title, "setPaintFlags", 0)
            views.setTextColor(R.id.todo_item_title, context.getColor(R.color.widget_text_primary))
        }

        // 2. 重要待办标绿点
        if (data.priority == "important") {
            views.setViewVisibility(R.id.todo_item_priority, android.view.View.VISIBLE)
        } else {
            views.setViewVisibility(R.id.todo_item_priority, android.view.View.GONE)
        }

        // 3. 点击勾选框触发自定义 toggle 广播
        val toggleIntent = Intent().apply {
            action = TodoWidgetProvider.ACTION_TODO_TOGGLE
            putExtra(TodoWidgetProvider.EXTRA_TODO_ID, data.id)
            putExtra(TodoWidgetProvider.EXTRA_TODO_STATUS, if (data.isCompleted) 1 else 0)
        }
        views.setOnClickFillInIntent(R.id.todo_item_checkbox, toggleIntent)

        // 4. 点击待办项文字直接跳转主应用待办界面
        val fillInIntent = Intent().apply {
            action = TodoWidgetProvider.ACTION_TODO_CLICK
            putExtra("route", "/todo")
        }
        views.setOnClickFillInIntent(R.id.todo_item_title, fillInIntent)

        return views
    }

    override fun getLoadingView(): RemoteViews? = null

    override fun getViewTypeCount(): Int = 1

    override fun getItemId(position: Int): Long = position.toLong()

    override fun hasStableIds(): Boolean = true
}
