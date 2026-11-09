import 'dart:convert';

import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/foundation.dart' show kIsWeb, kDebugMode;

class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._internal();
  static Database? _database;

  DatabaseHelper._internal();

  /// 每日屏幕时长快照表 DDL：系统 UsageStats 仅保留最近约 7 天，
  /// 需自行逐日落库才能回看历史与做周/月聚合，故建表语句在冷装、升级、
  /// schema 兜底三处共用同一份，避免字段漂移。
  static const String _screenUsageDailyDdl = '''
    CREATE TABLE IF NOT EXISTS screen_usage_daily (
      date TEXT PRIMARY KEY,
      total_time_ms INTEGER NOT NULL DEFAULT 0,
      top_apps_json TEXT DEFAULT '[]',
      is_complete INTEGER NOT NULL DEFAULT 0,
      source TEXT NOT NULL DEFAULT 'usage_stats',
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
  ''';

  /// 桌面小组件快照表 DDL：收支、心情、日记归属日等聚合口径全部实现在 Dart
  /// （stats_utils 带中文正则回退、diary_record.getEffectiveDate），原生裸 SQL
  /// 算不出与 App 一致的数字。改由 Dart 算完落库、原生只读渲染，冷装与升级共用
  /// 同一份避免字段漂移。
  ///
  /// (key, date) 复合主键：高频小值用 date=''，按日聚合用 'YYYY-MM-DD' + payload，
  /// 这样新增一类组件不必再迁移表结构。
  static const String _widgetSnapshotDdl = '''
    CREATE TABLE IF NOT EXISTS widget_snapshot (
      key TEXT NOT NULL,
      date TEXT NOT NULL DEFAULT '',
      value_num REAL,
      value_text TEXT,
      payload TEXT,
      updated_at TEXT NOT NULL,
      PRIMARY KEY (key, date)
    )
  ''';

  /// 厂商条目表 DDL：一个 URL + 一组 API Key + 一组已启用模型
  ///
  /// 取代旧 `ai_configs`（一个模型一行）。密钥与地址属于厂商，模型只是条目下的
  /// 勾选项，因此「多把 Key 轮询」与「扫描后按需启用多个模型」都落在同一条目上。
  /// `api_keys`/`models`/`model_catalog` 都是 JSON 字符串列，避免为可变长度数据
  /// 建从表（导出/同步按整行 toMap 传递，子表还要额外铺一套管道）。
  static const String _aiProvidersDdl = '''
    CREATE TABLE IF NOT EXISTS ai_providers (
      id TEXT PRIMARY KEY,
      vendor_id TEXT,
      name TEXT NOT NULL,
      provider_type TEXT NOT NULL,
      base_url TEXT NOT NULL,
      auth_mode TEXT NOT NULL DEFAULT 'api_key',
      account_routing TEXT NOT NULL DEFAULT 'rotate',
      account_affinity TEXT NOT NULL DEFAULT 'session',
      api_keys TEXT NOT NULL,
      models TEXT NOT NULL,
      model_catalog TEXT,
      catalog_updated_at TEXT,
      is_default INTEGER DEFAULT 0,
      enabled INTEGER NOT NULL DEFAULT 1,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
  ''';

  /// 订阅账号登录态表 DDL（一个厂商条目可多行 = 多账号）
  ///
  /// 与 `ai_providers` 分开：refresh token 是长期凭据，不写 `sync_log`、
  /// 不进备份导出清单，避免随 WebDAV 同步到别的设备或落在备份文件里。
  ///
  /// v31 起 `id` 是主键、`provider_id` 只是普通索引列：多账号轮换要求同一厂商
  /// 能同时挂多份登录态。老库（v30，`provider_id` 主键）由 `_onUpgrade` 重建。
  static const String _aiAccountsDdl = '''
    CREATE TABLE IF NOT EXISTS ai_accounts (
      id TEXT PRIMARY KEY,
      provider_id TEXT NOT NULL,
      kind TEXT NOT NULL DEFAULT 'raccoon',
      alias TEXT NOT NULL DEFAULT '',
      access_token TEXT NOT NULL,
      refresh_token TEXT NOT NULL DEFAULT '',
      expires_at TEXT,
      uid TEXT,
      display_name TEXT,
      phone TEXT,
      status TEXT NOT NULL DEFAULT 'active',
      enabled INTEGER NOT NULL DEFAULT 1,
      sort_order INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
  ''';

  /// 模型路由组表 DDL
  ///
  /// 一个组 = 一组已启用模型 + 一个选路策略，角色可把它当「虚拟模型」绑定。
  /// `members` 是 JSON 字符串列（成员厂商/模型/权重/启用），与 `ai_providers.models`
  /// 同一套做法：整行 `toMap()` 随 WebDAV 同步与备份走，不必为可变长度成员建从表。
  static const String _aiRouteGroupsDdl = '''
    CREATE TABLE IF NOT EXISTS ai_route_groups (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      strategy TEXT NOT NULL DEFAULT 'rotate',
      members TEXT NOT NULL DEFAULT '[]',
      pinned_member TEXT,
      prefer_vision INTEGER DEFAULT 1,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
  ''';

  /// Token 用量按日聚合表 DDL
  ///
  /// 按 `(date, provider_id, model_name)` 聚合：用户要看的是累计消耗，一个模型
  /// 一天最多一行，长期使用也不会膨胀。纯本机观测数据，不参与 WebDAV 同步与
  /// 备份导出（换设备后累计没有意义，多端合并还会把计数写冲突）。
  static const String _aiTokenUsageDdl = '''
    CREATE TABLE IF NOT EXISTS ai_token_usage_daily (
      date TEXT NOT NULL,
      provider_id TEXT NOT NULL DEFAULT '',
      model_name TEXT NOT NULL DEFAULT '',
      prompt_tokens INTEGER NOT NULL DEFAULT 0,
      completion_tokens INTEGER NOT NULL DEFAULT 0,
      total_tokens INTEGER NOT NULL DEFAULT 0,
      request_count INTEGER NOT NULL DEFAULT 0,
      updated_at TEXT NOT NULL,
      PRIMARY KEY (date, provider_id, model_name)
    )
  ''';

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
      version: 32,
      onConfigure: (db) async {
        // 遇到写锁时等待重试（默认立即抛 database is locked），提升并发访问健壮性
        try {
          await db.execute('PRAGMA busy_timeout = 5000');
        } catch (_) {
          // 个别平台（如 Web WASM）不支持该 PRAGMA，忽略即可
        }
      },
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
      onOpen: (db) async {
        await _checkAndAddMissingColumns(db);
      },
    );
  }

  Future<void> _checkAndAddMissingColumns(Database db) async {
    // 用 SharedPreferences 缓存 schema 已检查标记，避免每次启动都执行 PRAGMA 检查
    // 标记中包含数据库版本号，版本升级时自动重新检查一次
    final prefs = await SharedPreferences.getInstance();
    final checkedKey = 'schema_checked_v${await db.getVersion()}';
    if (prefs.getBool(checkedKey) == true) {
      return;
    }

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

    // 兜底：补 user_profiles 缺失 of 列
    try {
      final upColumns = await db.rawQuery('PRAGMA table_info(user_profiles)');
      final upColumnNames = upColumns.map((c) => c['name'] as String).toSet();
      if (upColumnNames.isNotEmpty && !upColumnNames.contains('custom_fields')) {
        await db.execute('ALTER TABLE user_profiles ADD COLUMN custom_fields TEXT DEFAULT "{}"');
      }
    } catch (_) {}

    try {
      final todoColumns = await db.rawQuery('PRAGMA table_info(todos)');
      final todoColNames = todoColumns.map((c) => c['name'] as String).toSet();
      if (todoColNames.isNotEmpty && !todoColNames.contains('repeat_rule')) {
        await db.execute("ALTER TABLE todos ADD COLUMN repeat_rule TEXT DEFAULT 'none'");
      }
    } catch (_) {}

    try {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS health_daily_metrics (
          date TEXT PRIMARY KEY,
          steps INTEGER DEFAULT 0,
          distance_meters REAL DEFAULT 0,
          calories REAL DEFAULT 0,
          active_minutes INTEGER DEFAULT 0,
          standing_count INTEGER DEFAULT 0,
          sleep_duration_minutes INTEGER DEFAULT 0,
          deep_sleep_minutes INTEGER DEFAULT 0,
          light_sleep_minutes INTEGER DEFAULT 0,
          rem_sleep_minutes INTEGER DEFAULT 0,
          awake_minutes INTEGER DEFAULT 0,
          sleep_start_time TEXT,
          sleep_end_time TEXT,
          sleep_score INTEGER,
          avg_heart_rate INTEGER,
          max_heart_rate INTEGER,
          min_heart_rate INTEGER,
          resting_heart_rate INTEGER,
          avg_spo2 INTEGER,
          min_spo2 INTEGER,
          avg_stress INTEGER,
          max_stress INTEGER,
          heart_rate_samples_json TEXT DEFAULT '[]',
          spo2_samples_json TEXT DEFAULT '[]',
          stress_samples_json TEXT DEFAULT '[]',
          sleep_stages_json TEXT DEFAULT '[]',
          source TEXT DEFAULT 'mi_fitness',
          updated_at TEXT NOT NULL
        )
      ''');
      // 兜底：补 health_daily_metrics 缺失 standing_count 列
      try {
        final hdmColumns = await db.rawQuery('PRAGMA table_info(health_daily_metrics)');
        final hdmColNames = hdmColumns.map((c) => c['name'] as String).toSet();
        if (hdmColNames.isNotEmpty && !hdmColNames.contains('standing_count')) {
          await db.execute('ALTER TABLE health_daily_metrics ADD COLUMN standing_count INTEGER DEFAULT 0');
        }
      } catch (_) {}
      await db.execute('''
        CREATE TABLE IF NOT EXISTS health_sport_records (
          id TEXT PRIMARY KEY,
          sid TEXT NOT NULL,
          category TEXT NOT NULL,
          title TEXT NOT NULL,
          start_time TEXT NOT NULL,
          end_time TEXT NOT NULL,
          duration_seconds INTEGER DEFAULT 0,
          distance_meters REAL DEFAULT 0,
          calories REAL DEFAULT 0,
          avg_pace REAL,
          max_pace REAL,
          avg_speed REAL,
          avg_heart_rate INTEGER,
          max_heart_rate INTEGER,
          steps INTEGER,
          avg_cadence INTEGER,
          track_geo_json TEXT,
          detail_json TEXT DEFAULT '{}',
          source TEXT DEFAULT 'mi_fitness',
          created_at TEXT NOT NULL
        )
      ''');
      await db.execute('CREATE INDEX IF NOT EXISTS idx_health_sport_sid ON health_sport_records(sid)');
      await db.execute('CREATE INDEX IF NOT EXISTS idx_health_sport_start ON health_sport_records(start_time)');
    } catch (_) {}

    // 兜底：确保 screen_usage_daily 存在（开发期热重载可能未触发 onUpgrade）
    try {
      await db.execute(_screenUsageDailyDdl);
    } catch (_) {}

    // 兜底：同上，桌面组件快照表在开发期热重载时也不会走 onUpgrade
    try {
      await db.execute(_widgetSnapshotDdl);
    } catch (_) {}

    // 兜底：厂商条目表同理（Web 与开发期热重载只走 onOpen 这条路）。
    // 缺表会让「添加模型服务」整条链路写入即抛 no such table，所以必须在这里补上。
    try {
      await db.execute(_aiProvidersDdl);
    } catch (_) {}

    // 兜底：Token 用量聚合表（同属 Web / 热重载只走 onOpen 的场景）
    try {
      await db.execute(_aiTokenUsageDdl);
    } catch (_) {}

    // 兜底：模型路由组表（同上；缺表会让路由组保存直接抛 no such table）
    try {
      await db.execute(_aiRouteGroupsDdl);
    } catch (_) {}

    // 兜底：订阅账号登录态表，以及 ai_providers 的 auth_mode 列。
    // Web 与开发期热重载只走 onOpen，缺列会让整行 toMap() 写入直接抛错。
    try {
      await db.execute(_aiAccountsDdl);
    } catch (_) {}
    // 兜底：v31 的多账号改造（老库 provider_id 主键 → id 主键 + 账号备注/启停/顺序），
    // 以及 ai_providers 的 auth_mode / account_routing / account_affinity 列
    try {
      final providerColumns = await db.rawQuery('PRAGMA table_info(ai_providers)');
      final providerColNames =
          providerColumns.map((c) => c['name'] as String).toSet();
      if (providerColNames.isNotEmpty &&
          !providerColNames.contains('auth_mode')) {
        await db.execute(
          "ALTER TABLE ai_providers ADD COLUMN auth_mode TEXT NOT NULL DEFAULT 'api_key'",
        );
      }
    } catch (_) {}
    await ensureMultiAccountSchema(db);

    // 兜底：补 chat_sessions 缺失的 is_pinned 列。这条是**主流程级**而非「置顶不生效」
    // 级别的问题——updateChatSession 是整行 toMap() 写库，列不存在会直接抛
    // no such column，用户表现为「发一条消息就报错」。Web(sqflite_common_ffi_web)
    // 与开发期热重载都只走 onOpen 这条路，不会走 _onUpgrade。
    try {
      final chatColumns = await db.rawQuery('PRAGMA table_info(chat_sessions)');
      final chatColNames = chatColumns.map((c) => c['name'] as String).toSet();
      if (chatColNames.isNotEmpty && !chatColNames.contains('is_pinned')) {
        await db.execute(
          'ALTER TABLE chat_sessions ADD COLUMN is_pinned INTEGER DEFAULT 0',
        );
      }
    } catch (_) {}

    // 标记本次检查已完成，后续启动直接跳过 PRAGMA 检查
    await prefs.setBool(checkedKey, true);
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
        repeat_rule TEXT DEFAULT 'none',
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
        custom_fields TEXT DEFAULT '{}',
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
        is_deleted INTEGER DEFAULT 0,
        is_pinned INTEGER DEFAULT 0
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

    await db.execute('''
      CREATE TABLE health_daily_metrics (
        date TEXT PRIMARY KEY,
        steps INTEGER DEFAULT 0,
        distance_meters REAL DEFAULT 0,
        calories REAL DEFAULT 0,
        active_minutes INTEGER DEFAULT 0,
        standing_count INTEGER DEFAULT 0,
        sleep_duration_minutes INTEGER DEFAULT 0,
        deep_sleep_minutes INTEGER DEFAULT 0,
        light_sleep_minutes INTEGER DEFAULT 0,
        rem_sleep_minutes INTEGER DEFAULT 0,
        awake_minutes INTEGER DEFAULT 0,
        sleep_start_time TEXT,
        sleep_end_time TEXT,
        sleep_score INTEGER,
        avg_heart_rate INTEGER,
        max_heart_rate INTEGER,
        min_heart_rate INTEGER,
        resting_heart_rate INTEGER,
        avg_spo2 INTEGER,
        min_spo2 INTEGER,
        avg_stress INTEGER,
        max_stress INTEGER,
        heart_rate_samples_json TEXT DEFAULT '[]',
        spo2_samples_json TEXT DEFAULT '[]',
        stress_samples_json TEXT DEFAULT '[]',
        sleep_stages_json TEXT DEFAULT '[]',
        source TEXT DEFAULT 'mi_fitness',
        updated_at TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE health_sport_records (
        id TEXT PRIMARY KEY,
        sid TEXT NOT NULL,
        category TEXT NOT NULL,
        title TEXT NOT NULL,
        start_time TEXT NOT NULL,
        end_time TEXT NOT NULL,
        duration_seconds INTEGER DEFAULT 0,
        distance_meters REAL DEFAULT 0,
        calories REAL DEFAULT 0,
        avg_pace REAL,
        max_pace REAL,
        avg_speed REAL,
        avg_heart_rate INTEGER,
        max_heart_rate INTEGER,
        steps INTEGER,
        avg_cadence INTEGER,
        track_geo_json TEXT,
        detail_json TEXT DEFAULT '{}',
        source TEXT DEFAULT 'mi_fitness',
        created_at TEXT NOT NULL
      )
    ''');

    await db.execute(_screenUsageDailyDdl);
    await db.execute(_widgetSnapshotDdl);
    await db.execute(_aiProvidersDdl);
    await db.execute(_aiTokenUsageDdl);
    await db.execute(_aiRouteGroupsDdl);
    await db.execute(_aiAccountsDdl);

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
      'CREATE INDEX IF NOT EXISTS idx_health_sport_sid ON health_sport_records(sid)',
      'CREATE INDEX IF NOT EXISTS idx_health_sport_start ON health_sport_records(start_time)',
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

    if (oldVersion < 18) {
      // 为活动标签的 type 选项追加"情绪"
      try {
        final rows = await db.query(
          'shortcut_configs',
          where: 'id = ?',
          whereArgs: ['activity'],
        );
        if (rows.isNotEmpty) {
          final fieldsJson = rows.first['fields'] as String?;
          if (fieldsJson != null) {
            final fieldsList = jsonDecode(fieldsJson) as List;
            for (var i = 0; i < fieldsList.length; i++) {
              final field = fieldsList[i] as Map<String, dynamic>;
              if (field['id'] == 'type') {
                final options = List<String>.from(field['options'] as List? ?? []);
                if (!options.contains('情绪')) {
                  options.add('情绪');
                  field['options'] = options;
                }
                break;
              }
            }
            await db.update(
              'shortcut_configs',
              {'fields': jsonEncode(fieldsList)},
              where: 'id = ?',
              whereArgs: ['activity'],
            );
          }
        }
      } catch (_) {}
    }

    if (oldVersion < 19) {
      // 为 user_profiles 表添加 custom_fields 列
      try {
        await db.execute('ALTER TABLE user_profiles ADD COLUMN custom_fields TEXT DEFAULT "{}"');
      } catch (_) {}
    }

    if (oldVersion < 20) {
      // 1. todos 表新增 repeat_rule 列
      try {
        await db.execute("ALTER TABLE todos ADD COLUMN repeat_rule TEXT DEFAULT 'none'");
      } catch (_) {}

      // 2. 初始化待办默认分类（今日、长期）并迁移存量待办的 folder_id
      try {
        final existingTodoFolders = await db.query(
          'folders',
          where: "type = 'todo'",
        );
        final nowStr = DateTime.now().toIso8601String();
        String todayFolderId = 'todo_default_today';
        String longtermFolderId = 'todo_default_longterm';

        if (existingTodoFolders.isEmpty) {
          await db.insert('folders', {
            'id': todayFolderId,
            'name': '今日',
            'parent_id': null,
            'type': 'todo',
            'sort_order': 0,
            'is_expanded': 1,
            'created_at': nowStr,
            'updated_at': nowStr,
          });
          await db.insert('folders', {
            'id': longtermFolderId,
            'name': '长期',
            'parent_id': null,
            'type': 'todo',
            'sort_order': 1,
            'is_expanded': 1,
            'created_at': nowStr,
            'updated_at': nowStr,
          });
        } else {
          todayFolderId = existingTodoFolders.first['id'] as String;
          longtermFolderId = existingTodoFolders.length > 1
              ? (existingTodoFolders[1]['id'] as String)
              : todayFolderId;
        }

        // 存量数据平滑迁移：folder_id 为空的数据根据 is_long_term 绑定默认分类
        await db.execute('''
          UPDATE todos 
          SET folder_id = '$longtermFolderId' 
          WHERE (folder_id IS NULL OR folder_id = '') AND is_long_term = 1
        ''');
        await db.execute('''
          UPDATE todos 
          SET folder_id = '$todayFolderId' 
          WHERE (folder_id IS NULL OR folder_id = '') AND (is_long_term = 0 OR is_long_term IS NULL)
        ''');
      } catch (_) {}
    }

    if (oldVersion < 21) {
      try {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS health_daily_metrics (
            date TEXT PRIMARY KEY,
            steps INTEGER DEFAULT 0,
            distance_meters REAL DEFAULT 0,
            calories REAL DEFAULT 0,
            active_minutes INTEGER DEFAULT 0,
            standing_count INTEGER DEFAULT 0,
            sleep_duration_minutes INTEGER DEFAULT 0,
            deep_sleep_minutes INTEGER DEFAULT 0,
            light_sleep_minutes INTEGER DEFAULT 0,
            rem_sleep_minutes INTEGER DEFAULT 0,
            awake_minutes INTEGER DEFAULT 0,
            sleep_start_time TEXT,
            sleep_end_time TEXT,
            sleep_score INTEGER,
            avg_heart_rate INTEGER,
            max_heart_rate INTEGER,
            min_heart_rate INTEGER,
            resting_heart_rate INTEGER,
            avg_spo2 INTEGER,
            min_spo2 INTEGER,
            avg_stress INTEGER,
            max_stress INTEGER,
            heart_rate_samples_json TEXT DEFAULT '[]',
            spo2_samples_json TEXT DEFAULT '[]',
            stress_samples_json TEXT DEFAULT '[]',
            sleep_stages_json TEXT DEFAULT '[]',
            source TEXT DEFAULT 'mi_fitness',
            updated_at TEXT NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE IF NOT EXISTS health_sport_records (
            id TEXT PRIMARY KEY,
            sid TEXT NOT NULL,
            category TEXT NOT NULL,
            title TEXT NOT NULL,
            start_time TEXT NOT NULL,
            end_time TEXT NOT NULL,
            duration_seconds INTEGER DEFAULT 0,
            distance_meters REAL DEFAULT 0,
            calories REAL DEFAULT 0,
            avg_pace REAL,
            max_pace REAL,
            avg_speed REAL,
            avg_heart_rate INTEGER,
            max_heart_rate INTEGER,
            steps INTEGER,
            avg_cadence INTEGER,
            track_geo_json TEXT,
            detail_json TEXT DEFAULT '{}',
            source TEXT DEFAULT 'mi_fitness',
            created_at TEXT NOT NULL
          )
        ''');
        await db.execute('CREATE INDEX IF NOT EXISTS idx_health_sport_sid ON health_sport_records(sid)');
        await db.execute('CREATE INDEX IF NOT EXISTS idx_health_sport_start ON health_sport_records(start_time)');
      } catch (_) {}
    }

    if (oldVersion < 22) {
      try {
        final hdmColumns = await db.rawQuery('PRAGMA table_info(health_daily_metrics)');
        final hdmColNames = hdmColumns.map((c) => c['name'] as String).toSet();
        if (hdmColNames.isNotEmpty && !hdmColNames.contains('standing_count')) {
          await db.execute('ALTER TABLE health_daily_metrics ADD COLUMN standing_count INTEGER DEFAULT 0');
        }
      } catch (_) {}
    }

    if (oldVersion < 23) {
      try {
        await db.execute(_screenUsageDailyDdl);
      } catch (_) {}
    }

    if (oldVersion < 24) {
      try {
        await db.execute(_widgetSnapshotDdl);
      } catch (_) {}
    }

    if (oldVersion < 25) {
      // 历史抽屉「置顶」：列名与 notes.is_pinned 保持一致，避免全库出现第二种写法
      try {
        await db.execute(
          'ALTER TABLE chat_sessions ADD COLUMN is_pinned INTEGER DEFAULT 0',
        );
      } catch (_) {}
    }

    if (oldVersion < 26) {
      // 该版本曾创建免费网关逐请求观测表，现已随内置模型一并下线；
      // v27 分支会把它 DROP 掉（新装库不再创建），此处无需再补建。
    }

    if (oldVersion < 27) {
      // 厂商条目表：取代模型级 ai_configs（数据迁移在 Dart 侧完成，
      // 因为要按「厂商+地址」分组归并密钥与模型，SQL 表达太绕）
      try {
        await db.execute(_aiProvidersDdl);
      } catch (_) {}
      // 内置模型发信诊断表随内置模型下线：只记录过内置 Key 掩码的本地数据，无保留价值
      try {
        await db.execute('DROP TABLE IF EXISTS ai_request_stats');
      } catch (_) {}
    }

    if (oldVersion < 28) {
      // Token 用量按日聚合表：AI 配置页的累计消耗卡片从这里读
      try {
        await db.execute(_aiTokenUsageDdl);
      } catch (_) {}
    }

    if (oldVersion < 29) {
      // 模型路由组表：一组已启用模型 + 选路策略，供角色绑定成「虚拟模型」
      try {
        await db.execute(_aiRouteGroupsDdl);
      } catch (_) {}
    }

    if (oldVersion < 30) {
      // 订阅账号登录态表 + 厂商条目的凭证类型列（商汤小浣熊）
      try {
        await db.execute(_aiAccountsDdl);
      } catch (_) {}
      try {
        final columns = await db.rawQuery('PRAGMA table_info(ai_providers)');
        final names = columns.map((c) => c['name'] as String).toSet();
        if (names.isNotEmpty && !names.contains('auth_mode')) {
          await db.execute(
            "ALTER TABLE ai_providers ADD COLUMN auth_mode TEXT NOT NULL DEFAULT 'api_key'",
          );
        }
      } catch (_) {}
    }

    if (oldVersion < 31) {
      // 多账号：ai_accounts 改主键结构 + 账号备注/启停/顺序，ai_providers 增加
      // 选号策略与亲和时长。老库只有一行一厂商，逐行搬过去即可；不写 sync_log
      // （该表本来就不参与同步）。
      await ensureMultiAccountSchema(db);
    }

    if (oldVersion < 32) {
      // 厂商级「停用」开关。web 与开发期热重载只走 onOpen，那里也有一份同样的
      // 列检查（见 ensureMultiAccountSchema）
      try {
        final columns = await db.rawQuery('PRAGMA table_info(ai_providers)');
        final names = columns.map((c) => c['name'] as String).toSet();
        if (names.isNotEmpty && !names.contains('enabled')) {
          await db.execute(
            'ALTER TABLE ai_providers ADD COLUMN enabled INTEGER NOT NULL DEFAULT 1',
          );
        }
      } catch (_) {}
    }
  }

  /// v31 的多账号 schema 迁移（`_onUpgrade` 与 `onOpen` 共用）
  ///
  /// 两步都要幂等：Web 与开发期热重载只走 `onOpen`，而正常升级只走
  /// `_onUpgrade`，任一路径漏掉都会让「多账号」落到一张没有 id 列的旧表上，
  /// 表现为写入直接抛 `no such column: id`。
  ///
  /// 老表（`provider_id` 主键，一厂商一行）搬迁时用 `provider_id` 当新主键：
  /// 值唯一、可读，而且不需要在 SQL 里生成 uuid。
  static Future<void> ensureMultiAccountSchema(Database db) async {
    try {
      final columns = await db.rawQuery('PRAGMA table_info(ai_accounts)');
      final names = columns.map((c) => c['name'] as String).toSet();
      if (names.isNotEmpty && !names.contains('id')) {
        await db.execute('ALTER TABLE ai_accounts RENAME TO ai_accounts_v30');
        await db.execute(_aiAccountsDdl);
        await db.execute('''
          INSERT OR REPLACE INTO ai_accounts (
            id, provider_id, kind, alias, access_token, refresh_token,
            expires_at, uid, display_name, phone, status, enabled,
            sort_order, created_at, updated_at
          )
          SELECT provider_id, provider_id, kind, '', access_token, refresh_token,
                 expires_at, uid, display_name, phone, status, 1,
                 0, created_at, updated_at
          FROM ai_accounts_v30
        ''');
        await db.execute('DROP TABLE ai_accounts_v30');
      } else if (names.isNotEmpty) {
        // 表已是最新结构，只补可能缺的列（半升级/手改库场景）
        if (!names.contains('alias')) {
          await db.execute(
            "ALTER TABLE ai_accounts ADD COLUMN alias TEXT NOT NULL DEFAULT ''",
          );
        }
        if (!names.contains('enabled')) {
          await db.execute(
            'ALTER TABLE ai_accounts ADD COLUMN enabled INTEGER NOT NULL DEFAULT 1',
          );
        }
        if (!names.contains('sort_order')) {
          await db.execute(
            'ALTER TABLE ai_accounts ADD COLUMN sort_order INTEGER NOT NULL DEFAULT 0',
          );
        }
      }
    } catch (_) {}
    try {
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_ai_accounts_provider '
        'ON ai_accounts(provider_id)',
      );
    } catch (_) {}
    try {
      final columns = await db.rawQuery('PRAGMA table_info(ai_providers)');
      final names = columns.map((c) => c['name'] as String).toSet();
      if (names.isNotEmpty && !names.contains('account_routing')) {
        await db.execute(
          "ALTER TABLE ai_providers ADD COLUMN account_routing TEXT NOT NULL DEFAULT 'rotate'",
        );
      }
      if (names.isNotEmpty && !names.contains('account_affinity')) {
        await db.execute(
          "ALTER TABLE ai_providers ADD COLUMN account_affinity TEXT NOT NULL DEFAULT 'session'",
        );
      }
      if (names.isNotEmpty && !names.contains('enabled')) {
        await db.execute(
          'ALTER TABLE ai_providers ADD COLUMN enabled INTEGER NOT NULL DEFAULT 1',
        );
      }
    } catch (_) {}
  }
}
