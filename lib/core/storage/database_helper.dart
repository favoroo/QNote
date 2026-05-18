import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'package:flutter/foundation.dart' show kIsWeb;

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
      version: 3,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
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
      CREATE TABLE body_states (
        id TEXT PRIMARY KEY,
        date TEXT NOT NULL,
        energy INTEGER DEFAULT 3,
        mood INTEGER DEFAULT 3,
        sleep_quality INTEGER DEFAULT 3,
        exercise INTEGER DEFAULT 0,
        weight REAL,
        note TEXT DEFAULT '',
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

    // Performance indexes
    await _createIndexes(db);
  }

  Future<void> _createIndexes(Database db) async {
    const indexes = [
      'CREATE INDEX IF NOT EXISTS idx_diary_time ON diary_records(time)',
      'CREATE INDEX IF NOT EXISTS idx_diary_is_deleted ON diary_records(is_deleted)',
      'CREATE INDEX IF NOT EXISTS idx_diary_display_tag ON diary_records(display_tag)',
      'CREATE INDEX IF NOT EXISTS idx_notes_folder ON notes(folder_id)',
      'CREATE INDEX IF NOT EXISTS idx_notes_is_deleted ON notes(is_deleted)',
      'CREATE INDEX IF NOT EXISTS idx_todos_completed ON todos(is_completed)',
      'CREATE INDEX IF NOT EXISTS idx_todos_is_deleted ON todos(is_deleted)',
      'CREATE INDEX IF NOT EXISTS idx_todos_long_term ON todos(is_long_term)',
      'CREATE INDEX IF NOT EXISTS idx_color_marks_date ON date_color_marks(date)',
    ];
    for (final sql in indexes) {
      try {
        await db.execute(sql);
      } catch (_) {}
    }
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      try {
        await db.execute('ALTER TABLE diary_records ADD COLUMN time TEXT');
      } catch (_) {}
      try {
        await db.execute(
          'ALTER TABLE diary_records ADD COLUMN start_time TEXT',
        );
      } catch (_) {}
      try {
        await db.execute('ALTER TABLE diary_records ADD COLUMN end_time TEXT');
      } catch (_) {}
      try {
        await db.execute(
          "ALTER TABLE diary_records ADD COLUMN display_tag TEXT DEFAULT ''",
        );
      } catch (_) {}
      try {
        await db.execute(
          'ALTER TABLE diary_records ADD COLUMN body_state TEXT',
        );
      } catch (_) {}
      try {
        await db.execute(
          "ALTER TABLE diary_records ADD COLUMN photos TEXT DEFAULT '[]'",
        );
      } catch (_) {}
      try {
        await db.execute(
          "ALTER TABLE diary_records ADD COLUMN color_mark TEXT DEFAULT ''",
        );
      } catch (_) {}

      try {
        await db.execute(
          'ALTER TABLE todos ADD COLUMN is_long_term INTEGER DEFAULT 0',
        );
      } catch (_) {}
      try {
        await db.execute('ALTER TABLE todos ADD COLUMN reminder_time TEXT');
      } catch (_) {}
      try {
        await db.execute('ALTER TABLE todos ADD COLUMN deadline TEXT');
      } catch (_) {}

      try {
        await db.execute(
          "ALTER TABLE notes ADD COLUMN images TEXT DEFAULT '[]'",
        );
      } catch (_) {}

      try {
        await db.execute(
          'ALTER TABLE shortcut_configs ADD COLUMN has_popup INTEGER DEFAULT 0',
        );
      } catch (_) {}
      try {
        await db.execute(
          "ALTER TABLE shortcut_configs ADD COLUMN fields TEXT DEFAULT '[]'",
        );
      } catch (_) {}
      try {
        await db.execute(
          'ALTER TABLE shortcut_configs ADD COLUMN categories TEXT',
        );
      } catch (_) {}
      try {
        await db.execute(
          'ALTER TABLE shortcut_configs ADD COLUMN image_extraction_prompt TEXT',
        );
      } catch (_) {}

      try {
        await db.execute('ALTER TABLE user_profiles ADD COLUMN name TEXT');
      } catch (_) {}
      try {
        await db.execute('ALTER TABLE user_profiles ADD COLUMN birthday TEXT');
      } catch (_) {}
      try {
        await db.execute('ALTER TABLE user_profiles ADD COLUMN height REAL');
      } catch (_) {}
      try {
        await db.execute(
          "ALTER TABLE user_profiles ADD COLUMN weight_history TEXT DEFAULT '[]'",
        );
      } catch (_) {}
      try {
        await db.execute('ALTER TABLE user_profiles ADD COLUMN gender TEXT');
      } catch (_) {}

      try {
        await db.execute('ALTER TABLE ai_configs ADD COLUMN name TEXT');
      } catch (_) {}
      try {
        await db.execute('ALTER TABLE ai_configs ADD COLUMN vendor_id TEXT');
      } catch (_) {}

      try {
        await db.execute(
          'ALTER TABLE folders ADD COLUMN is_expanded INTEGER DEFAULT 1',
        );
      } catch (_) {}

      await db.execute('''
        CREATE TABLE IF NOT EXISTS date_color_marks (
          id TEXT PRIMARY KEY,
          date TEXT NOT NULL,
          color TEXT NOT NULL
        )
      ''');

      await db.rawUpdate(
        "UPDATE todos SET priority = CASE WHEN priority = '0' OR priority = 0 THEN 'normal' WHEN priority = '1' OR priority = 1 THEN 'important' WHEN priority = '2' OR priority = 2 THEN 'important' ELSE 'normal' END WHERE typeof(priority) = 'integer' OR priority IN ('0', '1', '2')",
      );
    }
    if (oldVersion < 3) {
      await _createIndexes(db);
    }
  }
}
