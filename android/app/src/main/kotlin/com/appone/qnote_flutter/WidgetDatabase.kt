package com.appone.qnote_flutter

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * 桌面小组件访问 qnote.db 的统一入口。
 *
 * 抽出来的原因有三：三个组件此前各自 openDatabase 重复一份样板；原生连接没有
 * busy_timeout，与 Flutter sqflite 并发时会直接抛锁异常；写库跑在裸 Thread 上，
 * 进程被回收就静默丢失。
 */
object WidgetDatabase {
    private const val DB_NAME = "qnote.db"

    /** 与 lib/models/widget_snapshot.dart 的 WidgetSnapshotKeys 保持一致 */
    const val SNAPSHOT_TODO_PENDING_TODAY = "todo.pending_today"

    /** 「今日」在待办里是文件夹而非日期，id 见 lib/providers/todo_folder_provider.dart */
    const val TODAY_FOLDER_ID = "todo_default_today"

    /**
     * 「今日文件夹内的未完成待办」谓词，列表渲染与计数共用一份，避免两处条件各写各的而漂移。
     *
     * 语义严格对齐 lib/pages/todo_page.dart 的 currentFolderTodoIds 判定：显式挂在今日文件夹下
     * 的**优先**（即使是长期待办），只有未分配文件夹的才用「非长期」兜底。把 is_long_term = 0
     * 提出来当全局条件会少算前者。
     * 正常情况下组件读 Dart 写好的快照即可，这条 SQL 只在快照缺失时兜底，两者必须同口径。
     *
     * TODAY_FOLDER_ID 是编译期常量而非外部输入，直接内联无注入风险。
     */
    const val TODAY_PENDING_WHERE =
        "is_deleted = 0 AND is_completed = 0 AND TRIM(title) != '' " +
            "AND (folder_id = '$TODAY_FOLDER_ID' " +
            "OR ((folder_id IS NULL OR TRIM(folder_id) = '') AND is_long_term = 0))"

    /**
     * 串行化所有原生侧写库任务。
     *
     * 组件勾选与快捷记录可能同时触发，单线程队列保证原生自己不会和自己抢锁；
     * 与 Flutter 连接的冲突交给 busy_timeout + last-write-wins。
     */
    val executor: ExecutorService = Executors.newSingleThreadExecutor()

    /** 打开只读连接；库文件不存在或 ROM 读不到 WAL 附属文件时返回 null，由调用方走空态 */
    fun openReadonly(context: Context): SQLiteDatabase? = try {
        val file = context.getDatabasePath(DB_NAME)
        if (!file.exists()) null else SQLiteDatabase.openDatabase(file.absolutePath, null, SQLiteDatabase.OPEN_READONLY)
    } catch (e: Exception) {
        null
    }

    /** 打开读写连接；建库后立即补 busy_timeout，对齐 Dart 侧 onConfigure 的行为 */
    fun openReadwrite(context: Context): SQLiteDatabase? = try {
        val file = context.getDatabasePath(DB_NAME)
        if (!file.exists()) {
            null
        } else {
            val db = SQLiteDatabase.openDatabase(file.absolutePath, null, SQLiteDatabase.OPEN_READWRITE)
            // 只做 busy_timeout，绝不执行 PRAGMA journal_mode：改 WAL 模式会与 Flutter 连接互斥，
            // 且只读连接根本改不动。
            try {
                db.rawQuery("PRAGMA busy_timeout = 5000", null).use { it.moveToFirst() }
            } catch (e: Exception) {
            }
            db
        }
    } catch (e: Exception) {
        null
    }

    /** 今日文件夹内的未完成待办数（渲染兜底与勾选后就地刷新计数共用） */
    fun countTodayPending(db: SQLiteDatabase?): Int {
        if (db == null) return 0
        return try {
            db.rawQuery("SELECT COUNT(*) FROM todos WHERE $TODAY_PENDING_WHERE", null).use { cursor ->
                if (cursor.moveToFirst()) cursor.getInt(0) else 0
            }
        } catch (e: Exception) {
            0
        }
    }

    /**
     * 读取 Dart 写好的快照计数。
     *
     * 返回 null 表示快照缺失（首次开机、组件早于 App 第一次运行被放置），调用方应
     * 回落到 [countTodayPending]。刻意不做陈旧度判定：该值是文件夹归属计数，不随零点
     * 翻篇，漂移上限与「App 未运行期间外部同步带来的变化」一致。
     */
    fun snapshotInt(db: SQLiteDatabase?, key: String, date: String = ""): Int? {
        if (db == null) return null
        return try {
            db.rawQuery(
                "SELECT value_num FROM widget_snapshot WHERE key = ? AND date = ? LIMIT 1",
                arrayOf(key, date)
            ).use { cursor ->
                if (cursor.moveToFirst() && !cursor.isNull(0)) cursor.getInt(0) else null
            }
        } catch (e: Exception) {
            null
        }
    }

    /**
     * 原生写路径在同一事务内就地更新快照，保证勾选后桌面计数立刻正确，
     * 不必等下次回 App 由 Dart 覆写。
     *
     * 用 UPDATE 再 INSERT 而不是 INSERT OR REPLACE：后者会抹掉同一行已有的
     * payload/value_text；ON CONFLICT DO UPDATE 又要求 SQLite 3.24（minSdk 24 不保证）。
     */
    fun writeSnapshotInt(db: SQLiteDatabase, key: String, value: Int, date: String = "") {
        val now = iso8601()
        val values = ContentValues().apply {
            put("value_num", value)
            put("updated_at", now)
        }
        val updated = db.update("widget_snapshot", values, "key = ? AND date = ?", arrayOf(key, date))
        if (updated == 0) {
            values.put("key", key)
            values.put("date", date)
            db.insertWithOnConflict("widget_snapshot", null, values, SQLiteDatabase.CONFLICT_IGNORE)
        }
    }

    /** 统一的时间戳格式，与 Dart 的 toIso8601String() 前缀兼容 */
    fun iso8601(): String {
        val df = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS", Locale.US)
        df.timeZone = TimeZone.getDefault()
        return df.format(Date())
    }

    /**
     * 构造与 Flutter 侧 Todo.toMap() 逐字段一致的 JSON，供 sync_log 记录。
     * 原生两条待办写路径（小组件勾选、桌面快速添加）共用一份，避免拷贝漂移。
     *
     * 必须用 JSONObject 而不是字符串拼接：标题含双引号或换行时拼接会产出非法 JSON 行，
     * 直接污染 WebDAV 增量包（sync_log_repository 的 buildDeltaJson）。
     * 字段集合也要跟 Dart 对齐——此前漏了 repeat_rule，而对端 fromMap 缺省会填 'none'，
     * 在桌面勾选一条重复待办就可能把它的重复规则抹掉。
     * sort_order 用 Long：Dart addTodo 存毫秒时间戳， getInt 会截断到 32 位。
     */
    fun buildTodoJson(
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
        repeatRule: String,
        sortOrder: Long,
        createdAt: String,
        updatedAt: String
    ): String {
        return JSONObject().apply {
            put("id", id)
            put("title", title)
            put("description", desc)
            put("is_completed", if (isCompleted) 1 else 0)
            put("priority", priority)
            put("due_date", dueDate)
            put("tags", tags)
            put("folder_id", folderId)
            put("is_long_term", if (isLongTerm) 1 else 0)
            put("reminder_time", reminderTime)
            put("deadline", deadline)
            put("repeat_rule", repeatRule)
            put("sort_order", sortOrder)
            put("created_at", createdAt)
            put("updated_at", updatedAt)
            put("is_deleted", 0)
        }.toString()
    }
}
