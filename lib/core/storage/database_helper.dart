import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'package:flutter/foundation.dart' show kIsWeb, kDebugMode;

class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._internal();
  static Database? _database;

  DatabaseHelper._internal();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    String path;
    if (kIsWeb) {
      path = 'qnote.db';
    } else {
      final dbPath = await getDatabasesPath();
      path = p.join(dbPath, 'qnote.db');
    }

    return await openDatabase(
      path,
      version: 17,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
      onOpen: (db) async {
        await _checkAndAddMissingColumns(db);
      },
    );
  }

  Future<void> _checkAndAddMissingColumns(Database db) async {
    final columns = await db.rawQuery('PRAGMA table_info(diary_records)');
    final columnNames = columns.map((c) => c['name'] as String).toSet();

    if (!columnNames.contains('tag_entries')) {
      try {
        await db.execute('ALTER TABLE diary_records ADD COLUMN tag_entries TEXT');
      } catch (_) {}
    }
    if (!columnNames.contains('color_mark')) {
      try {
        await db.execute('ALTER TABLE diary_records ADD COLUMN color_mark TEXT DEFAULT ""');
      } catch (_) {}
    }
    if (!columnNames.contains('display_tag')) {
      try {
        await db.execute('ALTER TABLE diary_records ADD COLUMN display_tag TEXT DEFAULT ""');
      } catch (_) {}
    }
    if (!columnNames.contains('body_state')) {
      try {
        await db.execute('ALTER TABLE diary_records ADD COLUMN body_state TEXT');
      } catch (_) {}
    }

    try {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS daily_scores (
          id TEXT PRIMARY KEY,
          date TEXT NOT NULL,
          total_score INTEGER NOT NULL,
          dimension_scores TEXT NOT NULL,
          summary TEXT,
          suggestions TEXT,
          record_count INTEGER DEFAULT 0,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL
        )
      ''');
    } catch (_) {}

    try {
      await db.execute('CREATE INDEX IF NOT EXISTS idx_daily_scores_date ON daily_scores(date)');
    } catch (_) {}

    try {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS body_states (
          id TEXT PRIMARY KEY,
          name TEXT NOT NULL,
          severity TEXT,
          duration TEXT,
          triggers TEXT,
          notes TEXT,
          timestamp TEXT,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL
        )
      ''');
    } catch (_) {}

    // 兜底：补 fixed_event_templates 缺失 of 列（防老库跳版未走 _onUpgrade）
    try {
      final feColumns = await db.rawQuery('PRAGMA table_info(fixed_event_templates)');
      final feColumnNames = feColumns.map((c) => c['name'] as String).toSet();
      if (feColumnNames.isNotEmpty && !feColumnNames.contains('is_time_point')) {
        await db.execute('ALTER TABLE fixed_event_templates ADD COLUMN is_time_point INTEGER DEFAULT 0');
      }
      if (feColumnNames.isNotEmpty && !feColumnNames.contains('tag_fields')) {
        await db.execute('ALTER TABLE fixed_event_templates ADD COLUMN tag_fields TEXT DEFAULT "{}"');
      }
      if (feColumnNames.isNotEmpty && !feColumnNames.contains('time_periods')) {
        await db.execute('ALTER TABLE fixed_event_templates ADD COLUMN time_periods TEXT DEFAULT "[]"');
      }
    } catch (_) {}
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE diary_records (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        content TEXT NOT NULL DEFAULT '',
        mood INTEGER DEFAULT 3,
        weather TEXT DEFAULT '',
        tags TEXT DEFAULT '',
        folder_id TEXT,
        time TEXT,
        start_time TEXT,
        end_time TEXT,
        display_tag TEXT DEFAULT '',
        body_state TEXT,
        tag_entries TEXT,
        photos TEXT DEFAULT '[]',
        color_mark TEXT DEFAULT '',
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        is_deleted INTEGER DEFAULT 0
      )
    ''');

    await db.execute('''
      CREATE TABLE notes (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        content TEXT NOT NULL DEFAULT '',
        folder_id TEXT,
        tags TEXT DEFAULT '',
        is_pinned INTEGER DEFAULT 0,
        images TEXT DEFAULT '[]',
        sort_order INTEGER DEFAULT 0,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        is_deleted INTEGER DEFAULT 0
      )
    ''');

    await db.execute('''
      CREATE TABLE folders (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        parent_id TEXT,
        type TEXT NOT NULL DEFAULT 'note',
        sort_order INTEGER DEFAULT 0,
        is_expanded INTEGER DEFAULT 1,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE todos (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        description TEXT DEFAULT '',
        is_completed INTEGER DEFAULT 0,
        priority TEXT DEFAULT 'normal',
        due_date TEXT,
        tags TEXT DEFAULT '',
        folder_id TEXT,
        is_long_term INTEGER DEFAULT 0,
        reminder_time TEXT,
        deadline TEXT,
        sort_order INTEGER DEFAULT 0,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        is_deleted INTEGER DEFAULT 0
      )
    ''');

    await db.execute('''
      CREATE TABLE ai_configs (
        id TEXT PRIMARY KEY,
        provider TEXT NOT NULL,
        model_name TEXT NOT NULL,
        api_key TEXT NOT NULL,
        base_url TEXT NOT NULL,
        is_default INTEGER DEFAULT 0,
        temperature REAL DEFAULT 0.7,
        max_tokens INTEGER DEFAULT 2048,
        name TEXT,
        vendor_id TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE shortcut_configs (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        prompt TEXT NOT NULL,
        icon TEXT DEFAULT '',
        has_popup INTEGER DEFAULT 0,
        fields TEXT DEFAULT '[]',
        categories TEXT,
        image_extraction_prompt TEXT,
        sort_order INTEGER DEFAULT 0,
        is_visible INTEGER DEFAULT 1,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE user_profiles (
        id TEXT PRIMARY KEY,
        nickname TEXT DEFAULT '',
        avatar_path TEXT DEFAULT '',
        name TEXT,
        birthday TEXT,
        height REAL,
        weight_history TEXT DEFAULT '[]',
        gender TEXT,
        other_info TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE chat_sessions (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        messages TEXT NOT NULL DEFAULT '[]',
        ai_config_id TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        is_deleted INTEGER DEFAULT 0
      )
    ''');

    await db.execute('''
      CREATE TABLE webdav_configs (
        id TEXT PRIMARY KEY,
        server_url TEXT NOT NULL,
        username TEXT NOT NULL,
        password TEXT NOT NULL,
        remote_path TEXT DEFAULT 'QNote',
        auto_sync INTEGER DEFAULT 0,
        sync_interval INTEGER DEFAULT 30,
        last_sync_time TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE app_configs (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE date_color_marks (
        id TEXT PRIMARY KEY,
        date TEXT NOT NULL,
        color TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE sync_log (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        table_name TEXT NOT NULL,
        record_id TEXT NOT NULL,
        operation TEXT NOT NULL,
        data TEXT,
        timestamp TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE daily_scores (
        id TEXT PRIMARY KEY,
        date TEXT NOT NULL,
        total_score INTEGER NOT NULL,
        dimension_scores TEXT NOT NULL,
        summary TEXT,
        suggestions TEXT,
        record_count INTEGER DEFAULT 0,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE body_states (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        severity TEXT,
        duration TEXT,
        triggers TEXT,
        notes TEXT,
        timestamp TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE fixed_event_templates (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        start_time TEXT NOT NULL,
        end_time TEXT NOT NULL,
        is_time_point INTEGER DEFAULT 0,
        content TEXT DEFAULT '',
        tags TEXT DEFAULT '[]',
        tag_fields TEXT DEFAULT '{}',
        sort_order INTEGER DEFAULT 0,
        is_enabled INTEGER DEFAULT 1,
        time_periods TEXT DEFAULT '[]',
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');

    // Performance indexes
    await _createIndexes(db);
  }

  Future<void> _createIndexes(Database db) async {
    const indexes = [
      'CREATE INDEX IF NOT EXISTS idx_diary_time ON diary_records(time)',
      'CREATE INDEX IF NOT EXISTS idx_diary_is_deleted ON diary_records(is_deleted)',
      'CREATE INDEX IF NOT EXISTS idx_diary_display_tag ON diary_records(display_tag)',
      'CREATE INDEX IF NOT EXISTS idx_diary_folder ON diary_records(folder_id)',
      'CREATE INDEX IF NOT EXISTS idx_diary_updated_at ON diary_records(updated_at)',
      'CREATE INDEX IF NOT EXISTS idx_notes_folder ON notes(folder_id)',
      'CREATE INDEX IF NOT EXISTS idx_notes_is_deleted ON notes(is_deleted)',
      'CREATE INDEX IF NOT EXISTS idx_notes_updated_at ON notes(updated_at)',
      'CREATE INDEX IF NOT EXISTS idx_todos_completed ON todos(is_completed)',
      'CREATE INDEX IF NOT EXISTS idx_todos_is_deleted ON todos(is_deleted)',
      'CREATE INDEX IF NOT EXISTS idx_todos_long_term ON todos(is_long_term)',
      'CREATE INDEX IF NOT EXISTS idx_todos_folder ON todos(folder_id)',
      'CREATE INDEX IF NOT EXISTS idx_folders_type ON folders(type)',
      'CREATE INDEX IF NOT EXISTS idx_folders_parent_id ON folders(parent_id)',
      'CREATE INDEX IF NOT EXISTS idx_chat_sessions_updated_at ON chat_sessions(updated_at)',
      'CREATE INDEX IF NOT EXISTS idx_color_marks_date ON date_color_marks(date)',
      'CREATE INDEX IF NOT EXISTS idx_sync_log_timestamp ON sync_log(timestamp)',
      'CREATE INDEX IF NOT EXISTS idx_sync_log_table ON sync_log(table_name, record_id)',
      'CREATE INDEX IF NOT EXISTS idx_daily_scores_date ON daily_scores(date)',
      'CREATE INDEX IF NOT EXISTS idx_body_states_timestamp ON body_states(timestamp)',
      'CREATE INDEX IF NOT EXISTS idx_fixed_event_templates_sort ON fixed_event_templates(sort_order)',
    ];
    for (final sql in indexes) {
      try {
        await db.execute(sql);
      } catch (e) {
        if (kDebugMode) {
          print('创建索引失败: $sql, 错误: $e');
        }
      }
    }
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 11) {
      try {
        await db.execute('ALTER TABLE notes ADD COLUMN sort_order INTEGER DEFAULT 0');
      } catch (e) {
        if (kDebugMode) {
          print('升级数据库添加 sort_order 失败: $e');
        }
      }
    }
    if (oldVersion < 12) {
      try {
        await db.execute('ALTER TABLE diary_records ADD COLUMN tag_entries TEXT');
      } catch (_) {}
      try {
        await db.execute('ALTER TABLE diary_records ADD COLUMN color_mark TEXT DEFAULT ""');
      } catch (_) {}
      try {
        await db.execute('ALTER TABLE diary_records ADD COLUMN display_tag TEXT DEFAULT ""');
      } catch (_) {}
      try {
        await db.execute('ALTER TABLE diary_records ADD COLUMN body_state TEXT');
      } catch (_) {}

      try {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS daily_scores (
            id TEXT PRIMARY KEY,
            date TEXT NOT NULL,
            total_score INTEGER NOT NULL,
            dimension_scores TEXT NOT NULL,
            summary TEXT,
            suggestions TEXT,
            record_count INTEGER DEFAULT 0,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
          )
        ''');
      } catch (_) {}

      try {
        await db.execute('CREATE INDEX IF NOT EXISTS idx_daily_scores_date ON daily_scores(date)');
      } catch (_) {}
    }

    if (oldVersion < 13) {
      try {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS body_states (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            severity TEXT,
            duration TEXT,
            triggers TEXT,
            notes TEXT,
            timestamp TEXT,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
          )
        ''');
      } catch (_) {}

      try {
        await db.execute('CREATE INDEX IF NOT EXISTS idx_body_states_timestamp ON body_states(timestamp)');
      } catch (_) {}
    }

    if (oldVersion < 14) {
      try {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS fixed_event_templates (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            start_time TEXT NOT NULL,
            end_time TEXT NOT NULL,
            content TEXT DEFAULT '',
            tags TEXT DEFAULT '[]',
            sort_order INTEGER DEFAULT 0,
            is_enabled INTEGER DEFAULT 1,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
          )
        ''');
      } catch (_) {}

      try {
        await db.execute('CREATE INDEX IF NOT EXISTS idx_fixed_event_templates_sort ON fixed_event_templates(sort_order)');
      } catch (_) {}
    }

    if (oldVersion < 15) {
      // 为 fixed_event_templates 表添加 tag_fields 列
      try {
        await db.execute('ALTER TABLE fixed_event_templates ADD COLUMN tag_fields TEXT DEFAULT "{}"');
      } catch (_) {}
    }

    if (oldVersion < 16) {
      // 为 fixed_event_templates 表添加 is_time_point 列（时间点/时间段模式标志）
      try {
        await db.execute('ALTER TABLE fixed_event_templates ADD COLUMN is_time_point INTEGER DEFAULT 0');
      } catch (_) {}
    }

    if (oldVersion < 17) {
      // 为 fixed_event_templates 表添加 time_periods 列
      try {
        await db.execute('ALTER TABLE fixed_event_templates ADD COLUMN time_periods TEXT DEFAULT "[]"');
      } catch (_) {}
    }
  }
}
