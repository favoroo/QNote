import 'dart:convert';

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
      version: 9,
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
      'CREATE INDEX IF NOT EXISTS idx_sync_log_timestamp ON sync_log(timestamp)',
      'CREATE INDEX IF NOT EXISTS idx_sync_log_table ON sync_log(table_name, record_id)',
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
    if (oldVersion < 4) {
      try {
        await db.execute(
          'ALTER TABLE diary_records ADD COLUMN tag_entries TEXT',
        );
      } catch (_) {}
    }
    if (oldVersion < 5) {
      try {
        await db.execute(
          'ALTER TABLE user_profiles ADD COLUMN other_info TEXT',
        );
      } catch (_) {}
    }
    if (oldVersion < 6) {
      try {
        await db.execute(
          'ALTER TABLE todos ADD COLUMN sort_order INTEGER DEFAULT 0',
        );
      } catch (_) {}
    }
    if (oldVersion < 7) {
      try {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS sync_log (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            table_name TEXT NOT NULL,
            record_id TEXT NOT NULL,
            operation TEXT NOT NULL,
            data TEXT,
            timestamp TEXT NOT NULL
          )
        ''');
        await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_sync_log_timestamp ON sync_log(timestamp)',
        );
        await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_sync_log_table ON sync_log(table_name, record_id)',
        );
      } catch (_) {}
    }
    if (oldVersion < 8) {
      try {
        await db.execute(
          'ALTER TABLE shortcut_configs ADD COLUMN is_visible INTEGER DEFAULT 1',
        );
      } catch (_) {}
    }
    if (oldVersion < 9) {
      await _migrateV9(db);
    }
  }

  Future<void> _migrateV9(Database db) async {
    final optionUpdates = <String, Map<String, dynamic>>{
      'diet': {
        'fieldId': 'type',
        'oldOptions': ['正餐', '零食', '水果', '饮品'],
        'newOptions': ['自制', '外卖', '堂食', '零食', '水果', '饮品', '补剂'],
        'allowCustom': true,
      },
      'activity': {
        'fieldId': 'type',
        'oldOptions': ['工作', '学习', '娱乐', '运动'],
        'newOptions': ['工作', '学习', '运动', '社交', '娱乐', '通勤', '家务', '休息'],
        'allowCustom': true,
      },
      'health': {
        'fieldId': 'symptom',
        'oldOptions': ['脑雾', '疲劳', '头痛', '胃胀', '发热', '过敏', '失眠', '疼痛'],
        'newOptions': ['头痛', '疲劳', '失眠', '胃胀', '发热', '咳嗽', '疼痛', '过敏'],
        'allowCustom': true,
      },
    };

    final categoryOptionUpdates = <String, Map<String, Map<String, dynamic>>>{
      'consumption': {
        'expense': {
          'fieldId': 'type',
          'oldOptions': ['饮食', '交通', '购物', '娱乐', '居家', '人情', '医疗', '房租', '数码', '其他'],
          'newOptions': ['饮食', '交通', '购物', '娱乐', '居家', '人情', '医疗', '房租', '数码', '教育', '服饰', '美容', '宠物', '其他'],
          'allowCustom': true,
        },
        'income': {
          'fieldId': 'incomeType',
          'oldOptions': ['工资', '奖金', '红包', '兼职', '理财', '其他'],
          'newOptions': ['工资', '奖金', '红包', '兼职', '理财', '报销', '其他'],
          'allowCustom': true,
        },
      },
    };

    final rows = await db.query('shortcut_configs');
    for (final row in rows) {
      final id = row['id'] as String;
      bool updated = false;

      if (optionUpdates.containsKey(id)) {
        final fieldsJson = row['fields'] as String? ?? '[]';
        final fields = jsonDecode(fieldsJson) as List;
        final update = optionUpdates[id]!;
        for (int i = 0; i < fields.length; i++) {
          final field = fields[i] as Map<String, dynamic>;
          if (field['id'] == update['fieldId']) {
            final currentOptions = List<String>.from(field['options'] ?? []);
            if (_listsOverlap(currentOptions, update['oldOptions'] as List<String>)) {
              field['options'] = update['newOptions'];
              field['allowCustom'] = update['allowCustom'];
              updated = true;
            }
          }
        }
        if (updated) {
          await db.update(
            'shortcut_configs',
            {'fields': jsonEncode(fields)},
            where: 'id = ?',
            whereArgs: [id],
          );
        }
      }

      if (categoryOptionUpdates.containsKey(id)) {
        final categoriesJson = row['categories'] as String?;
        if (categoriesJson != null) {
          final categories = jsonDecode(categoriesJson) as List;
          final catUpdates = categoryOptionUpdates[id]!;
          bool catUpdated = false;
          for (int i = 0; i < categories.length; i++) {
            final cat = categories[i] as Map<String, dynamic>;
            final catId = cat['id'] as String?;
            if (catId != null && catUpdates.containsKey(catId)) {
              final update = catUpdates[catId]!;
              final catFields = cat['fields'] as List? ?? [];
              for (int j = 0; j < catFields.length; j++) {
                final field = catFields[j] as Map<String, dynamic>;
                if (field['id'] == update['fieldId']) {
                  final currentOptions = List<String>.from(field['options'] ?? []);
                  if (_listsOverlap(currentOptions, update['oldOptions'] as List<String>)) {
                    field['options'] = update['newOptions'];
                    field['allowCustom'] = update['allowCustom'];
                    catUpdated = true;
                  }
                }
              }
            }
          }
          if (catUpdated) {
            await db.update(
              'shortcut_configs',
              {'categories': jsonEncode(categories)},
              where: 'id = ?',
              whereArgs: [id],
            );
          }
        }
      }
    }

    final diaryRows = await db.query('diary_records', columns: ['id', 'tag_entries']);
    for (final row in diaryRows) {
      final tagEntriesJson = row['tag_entries'] as String?;
      if (tagEntriesJson == null || tagEntriesJson.isEmpty) continue;
      try {
        final tagEntries = jsonDecode(tagEntriesJson) as List;
        bool diaryUpdated = false;
        for (final entry in tagEntries) {
          if (entry is Map<String, dynamic>) {
            final entryId = entry['id'] as String?;
            if (entryId == 'diet') {
              final fields = entry['fields'];
              if (fields is Map && fields['type'] == '正餐') {
                fields['type'] = '自制';
                diaryUpdated = true;
              }
            }
          }
        }
        if (diaryUpdated) {
          await db.update(
            'diary_records',
            {'tag_entries': jsonEncode(tagEntries)},
            where: 'id = ?',
            whereArgs: [row['id']],
          );
        }
      } catch (_) {}
    }
  }

  bool _listsOverlap(List<String> a, List<String> b) {
    for (final item in b) {
      if (a.contains(item)) return true;
    }
    return false;
  }
}
