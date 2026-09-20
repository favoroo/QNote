package com.appone.qnote_flutter

import android.app.Activity
import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.database.sqlite.SQLiteDatabase
import android.os.Bundle
import android.view.KeyEvent
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
import android.widget.Button
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.Toast
import java.util.UUID

/**
 * 待办小组件「+」的桌面原生快速添加弹窗：透明浮层、不进 App，输入标题后
 * 直接落库并刷新小组件。骨架仿 QuickRecordActivity（同一套 Dialog 主题与卡片样式）。
 */
class QuickTodoAddActivity : Activity() {
    private lateinit var editTitle: EditText

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_quick_todo_add)

        editTitle = findViewById(R.id.edit_todo_title)
        findViewById<Button>(R.id.btn_dialog_cancel).setOnClickListener { finish() }
        findViewById<Button>(R.id.btn_dialog_add).setOnClickListener { addTodo(closeAfter = true) }
        // 点击弹窗外部空白处直接关闭
        findViewById<FrameLayout>(R.id.layout_root).setOnClickListener { finish() }

        // 回车连续添加：添加成功后清空输入、保持弹窗（对齐 App 内底部弹窗的回车连续添加习惯）
        editTitle.setOnEditorActionListener { _, actionId, event ->
            val isEnter = event != null &&
                event.action == KeyEvent.ACTION_DOWN &&
                event.keyCode == KeyEvent.KEYCODE_ENTER
            if (actionId == EditorInfo.IME_ACTION_DONE || isEnter) {
                addTodo(closeAfter = false)
                true
            } else {
                false
            }
        }

        // 自动聚焦并弹出软键盘
        editTitle.requestFocus()
        editTitle.postDelayed({
            val imm = getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
            imm.showSoftInput(editTitle, InputMethodManager.SHOW_IMPLICIT)
        }, 200)
    }

    private fun addTodo(closeAfter: Boolean) {
        val title = editTitle.text.toString().trim()
        if (title.isEmpty()) {
            Toast.makeText(this, "内容不能为空", Toast.LENGTH_SHORT).show()
            return
        }

        // 串行队列与小组件勾选、快捷记录共用，避免原生写路径互相抢锁
        WidgetDatabase.executor.execute {
            var db: SQLiteDatabase? = null
            var success = false
            try {
                val writable = WidgetDatabase.openReadwrite(this@QuickTodoAddActivity)
                if (writable == null) {
                    runOnUiThread {
                        Toast.makeText(this@QuickTodoAddActivity, "写入失败，请重试", Toast.LENGTH_SHORT).show()
                    }
                    return@execute
                }
                db = writable

                val id = UUID.randomUUID().toString()
                val nowStr = WidgetDatabase.iso8601()
                // 与 Dart addTodo 的 sortOrder=毫秒时间戳保持同一口径
                val sortOrder = System.currentTimeMillis()

                // 默认挂「今日」文件夹：命中小组件 TODAY_PENDING_WHERE，桌面列表立即出现，
                // App 内它同样归在「今日」文件夹下；提醒/重复等细节回 App 内编辑补齐
                val values = ContentValues().apply {
                    put("id", id)
                    put("title", title)
                    put("description", "")
                    put("is_completed", 0)
                    put("priority", "normal")
                    put("due_date", null as String?)
                    put("tags", "")
                    put("folder_id", WidgetDatabase.TODAY_FOLDER_ID)
                    put("is_long_term", 0)
                    put("reminder_time", null as String?)
                    put("deadline", null as String?)
                    put("repeat_rule", "none")
                    put("sort_order", sortOrder)
                    put("created_at", nowStr)
                    put("updated_at", nowStr)
                    put("is_deleted", 0)
                }

                // sync_log 载荷必须与 Dart 侧 Todo.toMap() 逐字段一致，否则对端 fromMap 会补默认值
                val dataJson = WidgetDatabase.buildTodoJson(
                    id = id,
                    title = title,
                    desc = "",
                    isCompleted = false,
                    priority = "normal",
                    dueDate = null,
                    tags = "",
                    folderId = WidgetDatabase.TODAY_FOLDER_ID,
                    isLongTerm = false,
                    reminderTime = null,
                    deadline = null,
                    repeatRule = "none",
                    sortOrder = sortOrder,
                    createdAt = nowStr,
                    updatedAt = nowStr
                )

                val logValues = ContentValues().apply {
                    put("table_name", "todos")
                    put("record_id", id)
                    put("operation", "insert")
                    put("data", dataJson)
                    put("timestamp", nowStr)
                }

                // 三笔写入放同一事务：只落一半会出现「本机有记录、云端增量里没有」或反过来的状态
                db.beginTransaction()
                try {
                    db.insert("todos", null, values)
                    db.insert("sync_log", null, logValues)
                    // 就地刷新今日计数，桌面计数立刻正确，不必等下次回 App 由 Dart 覆写
                    WidgetDatabase.writeSnapshotInt(
                        db,
                        WidgetDatabase.SNAPSHOT_TODO_PENDING_TODAY,
                        WidgetDatabase.countTodayPending(db)
                    )
                    db.setTransactionSuccessful()
                    success = true
                } finally {
                    db.endTransaction()
                }
            } catch (e: Exception) {
                e.printStackTrace()
            } finally {
                db?.close()
            }

            if (success) {
                // 通知桌面待办小组件数据有更新，重新渲染列表与计数
                val widgetManager = AppWidgetManager.getInstance(this@QuickTodoAddActivity)
                val component = ComponentName(this@QuickTodoAddActivity, TodoWidgetProvider::class.java)
                val widgetIds = widgetManager.getAppWidgetIds(component)
                val updateIntent = Intent(this@QuickTodoAddActivity, TodoWidgetProvider::class.java).apply {
                    action = AppWidgetManager.ACTION_APPWIDGET_UPDATE
                    putExtra(AppWidgetManager.EXTRA_APPWIDGET_IDS, widgetIds)
                }
                sendBroadcast(updateIntent)

                runOnUiThread {
                    Toast.makeText(this@QuickTodoAddActivity, "已添加", Toast.LENGTH_SHORT).show()
                    if (closeAfter) {
                        finish()
                    } else {
                        // 回车连续添加：清空输入、保持弹窗，并保持键盘拉起
                        editTitle.setText("")
                        editTitle.requestFocus()
                        val imm = getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
                        imm.showSoftInput(editTitle, InputMethodManager.SHOW_IMPLICIT)
                    }
                }
            } else {
                runOnUiThread {
                    Toast.makeText(this@QuickTodoAddActivity, "写入失败，请重试", Toast.LENGTH_SHORT).show()
                }
            }
        }
    }
}
