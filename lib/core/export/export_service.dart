import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:qnote_flutter/core/logger/logger_service.dart';
import 'package:qnote_flutter/core/storage/database_helper.dart';
import 'package:qnote_flutter/core/storage/diary_repository.dart';
import 'package:qnote_flutter/core/storage/note_repository.dart';
import 'package:qnote_flutter/core/storage/todo_repository.dart';
import 'package:qnote_flutter/core/storage/folder_repository.dart';
import 'package:qnote_flutter/core/storage/config_repository.dart';
import 'package:qnote_flutter/core/storage/color_mark_repository.dart';
import 'package:qnote_flutter/core/storage/image_repository.dart';
import 'package:qnote_flutter/models/diary_record.dart';
import 'package:qnote_flutter/models/note.dart';
import 'package:qnote_flutter/models/todo.dart';
import 'package:qnote_flutter/models/folder.dart';
import 'package:qnote_flutter/models/date_color_mark.dart';
import 'package:qnote_flutter/models/chat_session.dart';
import 'package:qnote_flutter/models/ai_config.dart';
import 'package:qnote_flutter/models/shortcut_config.dart';
import 'package:qnote_flutter/models/user_profile.dart';
import 'package:qnote_flutter/models/webdav_config.dart';
import 'package:qnote_flutter/models/ai_roles.dart';

class ExportService {
  final DiaryRepository _diaryRepo = DiaryRepository();
  final NoteRepository _noteRepo = NoteRepository();
  final TodoRepository _todoRepo = TodoRepository();
  final FolderRepository _folderRepo = FolderRepository();
  final ConfigRepository _configRepo = ConfigRepository.instance;
  final ColorMarkRepository _colorMarkRepo = ColorMarkRepository();
  final ImageRepository _imageRepo = ImageRepository();

  Future<String> exportDiaryAsMarkdown(List<DiaryRecord> records) async {
    final buffer = StringBuffer();
    buffer.writeln('# QNote 日记导出');
    buffer.writeln();
    for (final record in records) {
      buffer.writeln('## ${record.title}');
      buffer.writeln();
      buffer.writeln(
        '日期: ${record.createdAt.toIso8601String().substring(0, 10)}',
      );
      buffer.writeln('心情: ${record.mood}/5');
      if (record.weather.isNotEmpty) buffer.writeln('天气: ${record.weather}');
      if (record.tags.isNotEmpty) buffer.writeln('标签: ${record.tags}');
      buffer.writeln();
      buffer.writeln(record.content);
      buffer.writeln();
      buffer.writeln('---');
      buffer.writeln();
    }
    return buffer.toString();
  }

  Future<String> exportNotesAsMarkdown(List<Note> notes) async {
    final buffer = StringBuffer();
    buffer.writeln('# QNote 笔记导出');
    buffer.writeln();
    for (final note in notes) {
      buffer.writeln('## ${note.title}');
      buffer.writeln();
      if (note.tags.isNotEmpty) buffer.writeln('标签: ${note.tags}');
      buffer.writeln();
      buffer.writeln(note.content);
      buffer.writeln();
      buffer.writeln('---');
      buffer.writeln();
    }
    return buffer.toString();
  }

  Future<String> exportTodosAsMarkdown(List<Todo> todos) async {
    final buffer = StringBuffer();
    buffer.writeln('# QNote 待办导出');
    buffer.writeln();
    for (final todo in todos) {
      final status = todo.isCompleted ? '✅' : '⬜';
      buffer.writeln('- $status ${todo.title}');
      if (todo.description.isNotEmpty) {
        buffer.writeln('  - ${todo.description}');
      }
      if (todo.dueDate != null) {
        buffer.writeln(
          '  - 截止: ${todo.dueDate!.toIso8601String().substring(0, 10)}',
        );
      }
    }
    return buffer.toString();
  }

  Future<String> exportAllToJson({bool includeImages = true}) async {
    final startTime = DateTime.now();
    LoggerService.instance.logExport('开始导出所有数据为JSON...');

    final db = await DatabaseHelper.instance.database;
    final data = <String, dynamic>{};

    final diaries = await _diaryRepo.getAll(includeDeleted: true);
    LoggerService.instance.logExport('导出日记数据', details: '${diaries.length}条');

    final diaryMaps = <Map<String, dynamic>>[];
    for (final diary in diaries) {
      final map = diary.toMap();
      if (includeImages) {
        final photoBase64 = <String, String>{};
        for (int i = 0; i < diary.photos.length; i++) {
          final photoPath = diary.photos[i];
          if (photoPath.isNotEmpty) {
            final b64 = await _imageRepo.getBase64Image(photoPath);
            if (b64.isNotEmpty) {
              photoBase64[photoPath] = b64;
            }
          }
        }
        if (photoBase64.isNotEmpty) {
          map['photos_base64'] = photoBase64;
        }
      }
      diaryMaps.add(map);
    }
    data['diary_records'] = diaryMaps;

    final notes = await _noteRepo.getAll(includeDeleted: true);
    LoggerService.instance.logExport('导出笔记数据', details: '${notes.length}条');

    final noteMaps = <Map<String, dynamic>>[];
    for (final note in notes) {
      final map = note.toMap();
      if (includeImages) {
        final imageBase64 = <String, String>{};
        for (int i = 0; i < note.images.length; i++) {
          final imagePath = note.images[i];
          if (imagePath.isNotEmpty) {
            final b64 = await _imageRepo.getBase64Image(imagePath);
            if (b64.isNotEmpty) {
              imageBase64[imagePath] = b64;
            }
          }
        }
        if (imageBase64.isNotEmpty) {
          map['images_base64'] = imageBase64;
        }
      }
      noteMaps.add(map);
    }
    data['notes'] = noteMaps;

    final todoMaps = await db.query('todos');
    data['todos'] = todoMaps;

    final folderMaps = await db.query('folders');
    data['folders'] = folderMaps;

    final profile = await _configRepo.getUserProfile();
    if (profile != null) {
      data['user_profile'] = profile.toMap();
    }

    final aiConfigs = await _configRepo.getAllAiConfigs();
    data['ai_configs'] = aiConfigs.map((c) => c.toMap()).toList();

    final shortcutConfigs = await _configRepo.getAllShortcutConfigs();
    data['shortcut_configs'] = shortcutConfigs.map((c) => c.toMap()).toList();

    final chatSessions = await _configRepo.getAllChatSessions(
      includeDeleted: true,
    );
    data['chat_sessions'] = chatSessions.map((s) => s.toMap()).toList();

    final webdavConfig = await _configRepo.getWebdavConfig();
    if (webdavConfig != null) {
      final webdavMap = webdavConfig.toMap();
      webdavMap.remove('password');
      data['webdav_config'] = webdavMap;
    }

    final colorMarks = await _colorMarkRepo.getAll();
    data['date_color_marks'] = colorMarks.map((m) => m.toMap()).toList();

    final aiRoles = await _configRepo.getAiRoles();
    if (aiRoles != null) {
      data['ai_roles'] = aiRoles.toMap();
    }

    final aiTemps = await _configRepo.getAiTemperatures();
    if (aiTemps != null) {
      data['ai_temperatures'] = aiTemps.toMap();
    }

    final bodyStateMaps = await db.query('body_states');
    data['body_states'] = bodyStateMaps;

    final dailyScoreMaps = await db.query('daily_scores');
    data['daily_scores'] = dailyScoreMaps;

    data['export_version'] = 2;
    data['export_time'] = DateTime.now().toIso8601String();

    final jsonStr = const JsonEncoder.withIndent('  ').convert(data);
    final duration = DateTime.now().difference(startTime).inMilliseconds;

    LoggerService.instance.logExport(
      '数据导出完成',
      details:
          '耗时=${duration}ms, 大小≈${(jsonStr.length / 1024).toStringAsFixed(1)}KB',
    );

    return jsonStr;
  }

  Future<void> importFromJson(String filePath, {bool overwrite = true}) async {
    final file = File(filePath);
    if (!await file.exists()) {
      throw Exception('文件不存在: $filePath');
    }
    final jsonString = await file.readAsString();
    await importFromJsonString(jsonString, overwrite: overwrite);
  }

  Future<void> importFromJsonString(
    String jsonString, {
    bool overwrite = true,
  }) async {
    final startTime = DateTime.now();

    LoggerService.instance.logImport(
      '开始导入数据',
      details: overwrite ? '覆盖模式' : '合并模式',
    );

    final data = jsonDecode(jsonString) as Map<String, dynamic>;

    Map<String, dynamic> importData = data;

    if (data.containsKey('metadata') && data['metadata'] is Map) {
      LoggerService.instance.logImport(
        '检测到WebDAV格式的备份数据',
        details: '自动提取metadata字段中的实际数据',
      );
      importData = Map<String, dynamic>.from(data['metadata']);
    }

    // 转换旧架构数据格式
    importData = _transformOldArchitectureData(importData);

    _validateBackupData(importData);

    final db = await DatabaseHelper.instance.database;

    if (overwrite) {
      await _clearAllData(db);
    }

    if (importData.containsKey('folders')) {
      final folders = (importData['folders'] as List)
          .map((e) => Map<String, dynamic>.from(e as Map)).toList();
      await _importFolders(folders, overwrite);
    }

    if (importData.containsKey('diary_records')) {
      final records = (importData['diary_records'] as List)
          .map((e) => Map<String, dynamic>.from(e as Map)).toList();
      await _importDiaryRecords(records, overwrite);
    }

    if (importData.containsKey('notes')) {
      final notes = (importData['notes'] as List)
          .map((e) => Map<String, dynamic>.from(e as Map)).toList();
      await _importNotes(notes, overwrite);
    }

    if (importData.containsKey('todos')) {
      final todos = (importData['todos'] as List)
          .map((e) => Map<String, dynamic>.from(e as Map)).toList();
      await _importTodos(todos, overwrite);
    }

    if (importData.containsKey('user_profile')) {
      final profileMap = Map<String, dynamic>.from(importData['user_profile'] as Map);
      await _importUserProfile(profileMap, overwrite);
    }

    if (importData.containsKey('ai_configs')) {
      final configs = (importData['ai_configs'] as List)
          .map((e) => Map<String, dynamic>.from(e as Map)).toList();
      await _importAiConfigs(configs, overwrite);
    }

    if (importData.containsKey('shortcut_configs')) {
      final configs = (importData['shortcut_configs'] as List)
          .map((e) => Map<String, dynamic>.from(e as Map)).toList();
      await _importShortcutConfigs(configs, overwrite);
    }

    if (importData.containsKey('chat_sessions')) {
      final sessions = (importData['chat_sessions'] as List)
          .map((e) => Map<String, dynamic>.from(e as Map)).toList();
      await _importChatSessions(sessions, overwrite);
    }

    if (importData.containsKey('webdav_config')) {
      final webdavMap = Map<String, dynamic>.from(importData['webdav_config'] as Map);
      await _importWebdavConfig(webdavMap, overwrite);
    }

    if (importData.containsKey('date_color_marks')) {
      final marks = (importData['date_color_marks'] as List)
          .map((e) => Map<String, dynamic>.from(e as Map)).toList();
      await _importColorMarks(marks, overwrite);
    }

    if (importData.containsKey('ai_roles')) {
      final rolesMap = Map<String, dynamic>.from(importData['ai_roles'] as Map);
      final roles = AiRoles.fromMap(rolesMap);
      await _configRepo.saveAiRoles(roles);
    }

    if (importData.containsKey('ai_temperatures')) {
      final tempsMap = Map<String, dynamic>.from(importData['ai_temperatures'] as Map);
      final temps = AiTemperatures.fromMap(tempsMap);
      await _configRepo.saveAiTemperatures(temps);
    }

    if (importData.containsKey('body_states')) {
      final states = (importData['body_states'] as List)
          .map((e) => Map<String, dynamic>.from(e as Map)).toList();
      await _importBodyStates(states, overwrite);
    }

    if (importData.containsKey('daily_scores')) {
      final dailyScores = (importData['daily_scores'] as List)
          .map((e) => Map<String, dynamic>.from(e as Map)).toList();
      await _importDailyScores(dailyScores, overwrite);
    }

    final duration = DateTime.now().difference(startTime).inMilliseconds;
    final summary = StringBuffer('耗时=${duration}ms');
    if (importData.containsKey('diary_records')) summary.write(', 日记=${(importData['diary_records'] as List).length}');
    if (importData.containsKey('notes')) summary.write(', 笔记=${(importData['notes'] as List).length}');
    if (importData.containsKey('todos')) summary.write(', 待办=${(importData['todos'] as List).length}');
    if (importData.containsKey('folders')) summary.write(', 文件夹=${(importData['folders'] as List).length}');
    if (importData.containsKey('ai_configs')) summary.write(', AI配置=${(importData['ai_configs'] as List).length}');
    LoggerService.instance.logImport('数据导入完成', details: summary.toString());
  }

  void _validateBackupData(Map<String, dynamic> data) {
    final validKeys = {
      'diary_records',
      'notes',
      'todos',
      'folders',
      'user_profile',
      'ai_configs',
      'shortcut_configs',
      'chat_sessions',
      'webdav_config',
      'date_color_marks',
      'ai_roles',
      'ai_temperatures',
      'body_states',
      'daily_scores',
      'export_version',
      'export_time',
      // 允许一些旧架构的冗余字段，避免验证失败
      'qnote_active_ai_config_id',
      'qnote_vendor_api_keys',
      'qnote_batch_test_results',
    };
    for (final key in data.keys) {
      if (!validKeys.contains(key)) {
        // 如果是以 qnote_ 开头但未映射的字段，记录日志但不抛出异常
        if (key.startsWith('qnote_')) {
          LoggerService.instance.logImport('跳过未知的旧架构字段: $key');
          continue;
        }
        throw Exception('无效的备份数据: 未知字段 "$key"');
      }
    }
  }

  Future<void> _clearAllData(Database db) async {
    await db.delete('diary_records');
    await db.delete('notes');
    await db.delete('todos');
    await db.delete('folders');
    await db.delete('user_profiles');
    await db.delete('ai_configs');
    await db.delete('shortcut_configs');
    await db.delete('chat_sessions');
    await db.delete('webdav_configs');
    await db.delete('date_color_marks');
    await db.delete('body_states');
    await db.delete('daily_scores');
    await db.delete('app_configs');
  }

  Future<void> _importFolders(
    List<Map<String, dynamic>> folders,
    bool merge,
  ) async {
    for (final map in folders) {
      if (merge) {
        final existing = await _folderRepo.getById(map['id'] as String);
        if (existing != null) continue;
      }
      try {
        await _folderRepo.insert(Folder.fromMap(map));
      } catch (e) {
        LoggerService.instance.logImport('导入文件夹失败: ${map['id']}', level: LogLevel.error, details: e.toString());
      }
    }
  }

  Future<void> _importDiaryRecords(
    List<Map<String, dynamic>> records,
    bool merge,
  ) async {
    for (final map in records) {
      if (merge) {
        final existing = await _diaryRepo.getById(map['id'] as String);
        if (existing != null) continue;
      }
      try {
        final photosBase64 = map.remove('photos_base64');
        if (photosBase64 is Map) {
          final photoMap = Map<String, dynamic>.from(photosBase64);
          final photos = <String>[];
          for (final entry in photoMap.entries) {
            final savedPath = await _imageRepo.saveBase64Image(
              entry.value as String,
              subfolder: 'diary',
            );
            photos.add(savedPath);
          }
          if (photos.isNotEmpty) {
            map['photos'] = jsonEncode(photos);
          }
        }
        await _diaryRepo.insert(DiaryRecord.fromMap(map));
      } catch (e) {
        LoggerService.instance.logImport('导入日记失败: ${map['id']}', level: LogLevel.error, details: e.toString());
      }
    }
  }

  Future<void> _importNotes(
    List<Map<String, dynamic>> notes,
    bool merge,
  ) async {
    for (final map in notes) {
      if (merge) {
        final existing = await _noteRepo.getById(map['id'] as String);
        if (existing != null) continue;
      }
      try {
        final imagesBase64 = map.remove('images_base64');
        if (imagesBase64 is Map) {
          final imageMap = Map<String, dynamic>.from(imagesBase64);
          final images = <String>[];
          for (final entry in imageMap.entries) {
            final savedPath = await _imageRepo.saveBase64Image(
              entry.value as String,
              subfolder: 'notes',
            );
            images.add(savedPath);
          }
          if (images.isNotEmpty) {
            map['images'] = jsonEncode(images);
          }
        }
        await _noteRepo.insert(Note.fromMap(map));
      } catch (e) {
        LoggerService.instance.logImport('导入笔记失败: ${map['id']}', level: LogLevel.error, details: e.toString());
      }
    }
  }

  Future<void> _importTodos(
    List<Map<String, dynamic>> todos,
    bool merge,
  ) async {
    for (final map in todos) {
      if (merge) {
        final existing = await _todoRepo.getById(map['id'] as String);
        if (existing != null) continue;
      }
      try {
        await _todoRepo.insert(Todo.fromMap(map));
      } catch (e) {
        LoggerService.instance.logImport('导入待办失败: ${map['id']}', level: LogLevel.error, details: e.toString());
      }
    }
  }

  Future<void> _importUserProfile(Map<String, dynamic> map, bool merge) async {
    try {
      final profile = UserProfile.fromMap(map);
      await _configRepo.upsertUserProfile(profile);
    } catch (e) {
      LoggerService.instance.logImport('导入用户资料失败', level: LogLevel.error, details: e.toString());
    }
  }

  Future<void> _importAiConfigs(
    List<Map<String, dynamic>> configs,
    bool merge,
  ) async {
    for (final map in configs) {
      if (merge) {
        final existing = await _configRepo.getDefaultAiConfig();
        if (existing != null && existing.id == map['id']) continue;
      }
      try {
        await _configRepo.insertAiConfig(AiConfig.fromMap(map));
      } catch (e) {
        LoggerService.instance.logImport('导入AI配置失败: ${map['id']}', level: LogLevel.error, details: e.toString());
      }
    }
  }

  Future<void> _importShortcutConfigs(
    List<Map<String, dynamic>> configs,
    bool merge,
  ) async {
    for (final map in configs) {
      if (merge) {
        final existing = await _configRepo.getShortcutConfigs();
        if (existing.any((c) => c.id == map['id'])) continue;
      }
      try {
        await _configRepo.insertShortcutConfig(ShortcutConfig.fromMap(map));
      } catch (e) {
        LoggerService.instance.logImport('导入快捷配置失败: ${map['id']}', level: LogLevel.error, details: e.toString());
      }
    }
  }

  Future<void> _importChatSessions(
    List<Map<String, dynamic>> sessions,
    bool merge,
  ) async {
    for (final map in sessions) {
      if (merge) {
        final existing = await _configRepo.getChatSession(map['id'] as String);
        if (existing != null) continue;
      }
      try {
        await _configRepo.insertChatSession(ChatSession.fromMap(map));
      } catch (e) {
        LoggerService.instance.logImport('导入聊天会话失败: ${map['id']}', level: LogLevel.error, details: e.toString());
      }
    }
  }

  Future<void> _importWebdavConfig(Map<String, dynamic> map, bool merge) async {
    try {
      final existing = await _configRepo.getWebdavConfig();
      if (merge && existing != null) return;
      if (!map.containsKey('password')) {
        if (existing != null) {
          map['password'] = existing.password;
        } else {
          return;
        }
      }
      await _configRepo.upsertWebdavConfig(WebdavConfig.fromMap(map));
    } catch (e) {
      LoggerService.instance.logImport('导入WebDAV配置失败', level: LogLevel.error, details: e.toString());
    }
  }

  Future<void> _importColorMarks(
    List<Map<String, dynamic>> marks,
    bool merge,
  ) async {
    for (final map in marks) {
      try {
        await _colorMarkRepo.insert(DateColorMark.fromMap(map));
      } catch (_) {}
    }
  }

  Future<void> _importBodyStates(
    List<Map<String, dynamic>> states,
    bool merge,
  ) async {
    final db = await DatabaseHelper.instance.database;
    for (final map in states) {
      if (merge) {
        final existing = await db.query(
          'body_states',
          where: 'id = ?',
          whereArgs: [map['id']],
        );
        if (existing.isNotEmpty) continue;
      }
      try {
        await db.insert(
          'body_states',
          map,
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      } catch (_) {}
    }
  }

  Future<void> _importDailyScores(
    List<Map<String, dynamic>> dailyScores,
    bool merge,
  ) async {
    final db = await DatabaseHelper.instance.database;
    for (final map in dailyScores) {
      if (merge) {
        final existing = await db.query(
          'daily_scores',
          where: 'id = ?',
          whereArgs: [map['id']],
        );
        if (existing.isNotEmpty) continue;
      }
      try {
        await db.insert(
          'daily_scores',
          map,
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      } catch (_) {}
    }
  }

  Map<String, dynamic> _transformOldArchitectureData(Map<String, dynamic> data) {
    // 检测是否为旧架构：检查 qnote_ 前缀或 metadata 格式
    bool isOld = data.keys.any((k) => k.startsWith('qnote_'));
    if (!isOld) return data;

    LoggerService.instance.logImport('正在转换旧架构数据格式...');
    final result = <String, dynamic>{};

    // 键名映射 (qnote_ 前缀转换)
    final keyMap = {
      'qnote_diary': 'diary_records',
      'qnote_notes': 'notes',
      'qnote_todos': 'todos',
      'qnote_folders': 'folders',
      'qnote_user_profile': 'user_profile',
      'qnote_ai_configs': 'ai_configs',
      'qnote_ai_roles': 'ai_roles',
      'qnote_webdav_config': 'webdav_config',
      'qnote_body_states': 'body_states',
      'qnote_chat_sessions': 'chat_sessions',
      'qnote_date_color_marks': 'date_color_marks',
    };

    data.forEach((key, value) {
      final newKey = keyMap[key] ?? key;
      result[newKey] = value;
    });

    // 1. 标准化日记 (Diary)
    if (result.containsKey('diary_records') && result['diary_records'] is List) {
      final list = (result['diary_records'] as List);
      result['diary_records'] = list.map((item) {
        if (item is! Map) return item;
        final m = Map<String, dynamic>.from(item);
        _mapField(m, 'startTime', 'start_time');
        _mapField(m, 'endTime', 'end_time');
        _mapField(m, 'displayTag', 'display_tag');
        _mapField(m, 'createdAt', 'created_at');
        _mapField(m, 'updatedAt', 'updated_at');
        _mapField(m, 'isDeleted', 'is_deleted');
        _mapField(m, 'folderId', 'folder_id');
        _mapField(m, 'colorMark', 'color_mark');

        if (m['tags'] is List) m['tags'] = jsonEncode(m['tags']);
        if (m['photos'] is List) m['photos'] = jsonEncode(m['photos']);
        if (m['bodyState'] != null) {
          final bs = m.remove('bodyState');
          m['body_state'] = bs is Map ? jsonEncode(bs) : bs;
        }

        if (m['created_at'] == null) {
          m['created_at'] = DateTime.now().toIso8601String();
        }
        if (m['updated_at'] == null) m['updated_at'] = m['created_at'];
        if (m['is_deleted'] is bool) {
          m['is_deleted'] = (m['is_deleted'] as bool) ? 1 : 0;
        }
        if (m['title'] == null || (m['title'] is String && (m['title'] as String).isEmpty)) {
          final contentStr = (m['content'] as String? ?? '');
          var autoTitle = contentStr.split('\n').first;
          if (autoTitle.length > 30) autoTitle = autoTitle.substring(0, 30);
          m['title'] = autoTitle.isEmpty ? '无标题' : autoTitle;
        }
        return m;
      }).toList();
    }

    // 2. 标准化笔记 (Notes)
    if (result.containsKey('notes') && result['notes'] is List) {
      final list = (result['notes'] as List);
      result['notes'] = list.map((item) {
        if (item is! Map) return item;
        final m = Map<String, dynamic>.from(item);
        _mapField(m, 'folderId', 'folder_id');
        _mapField(m, 'isPinned', 'is_pinned');
        _mapField(m, 'createdAt', 'created_at');
        _mapField(m, 'updatedAt', 'updated_at');
        _mapField(m, 'isDeleted', 'is_deleted');

        if (m['images'] is List) m['images'] = jsonEncode(m['images']);
        if (m['tags'] is List) m['tags'] = (m['tags'] as List).join(',');

        if (m['created_at'] == null) {
          m['created_at'] = DateTime.now().toIso8601String();
        }
        if (m['updated_at'] == null) m['updated_at'] = m['created_at'];
        if (m['is_deleted'] is bool) {
          m['is_deleted'] = (m['is_deleted'] as bool) ? 1 : 0;
        }
        if (m['is_pinned'] is bool) {
          m['is_pinned'] = (m['is_pinned'] as bool) ? 1 : 0;
        }
        return m;
      }).toList();
    }

    // 3. 标准化待办 (Todos)
    if (result.containsKey('todos') && result['todos'] is List) {
      final list = (result['todos'] as List);
      result['todos'] = list.map((item) {
        if (item is! Map) return item;
        final m = Map<String, dynamic>.from(item);
        _mapField(m, 'isCompleted', 'is_completed');
        _mapField(m, 'isLongTerm', 'is_long_term');
        _mapField(m, 'dueDate', 'due_date');
        _mapField(m, 'folderId', 'folder_id');
        _mapField(m, 'createdAt', 'created_at');
        _mapField(m, 'updatedAt', 'updated_at');
        _mapField(m, 'isDeleted', 'is_deleted');

        if (m['created_at'] == null) {
          m['created_at'] = DateTime.now().toIso8601String();
        }
        if (m['updated_at'] == null) m['updated_at'] = m['created_at'];
        if (m['is_completed'] is bool) {
          m['is_completed'] = (m['is_completed'] as bool) ? 1 : 0;
        }
        if (m['is_long_term'] is bool) {
          m['is_long_term'] = (m['is_long_term'] as bool) ? 1 : 0;
        }
        if (m['is_deleted'] is bool) {
          m['is_deleted'] = (m['is_deleted'] as bool) ? 1 : 0;
        }
        return m;
      }).toList();
    }

    // 4. 标准化文件夹 (Folders)
    if (result.containsKey('folders') && result['folders'] is List) {
      final list = (result['folders'] as List);
      result['folders'] = list.map((item) {
        if (item is! Map) return item;
        final m = Map<String, dynamic>.from(item);
        _mapField(m, 'parentId', 'parent_id');
        _mapField(m, 'createdAt', 'created_at');
        _mapField(m, 'updatedAt', 'updated_at');
        _mapField(m, 'isExpanded', 'is_expanded');
        _mapField(m, 'sortOrder', 'sort_order');
        if (m['is_expanded'] is bool) {
          m['is_expanded'] = (m['is_expanded'] as bool) ? 1 : 0;
        }
        if (m['created_at'] == null) {
          m['created_at'] = DateTime.now().toIso8601String();
        }
        if (m['updated_at'] == null) m['updated_at'] = m['created_at'];
        return m;
      }).toList();
    }

    // 5. 标准化 AI 配置 (AI Configs)
    if (result.containsKey('ai_configs') && result['ai_configs'] is List) {
      final list = (result['ai_configs'] as List);
      result['ai_configs'] = list.map((item) {
        if (item is! Map) return item;
        final m = Map<String, dynamic>.from(item);
        _mapField(m, 'modelName', 'model_name');
        _mapField(m, 'apiKey', 'api_key');
        _mapField(m, 'baseUrl', 'base_url');
        _mapField(m, 'isDefault', 'is_default');
        _mapField(m, 'vendorId', 'vendor_id');
        _mapField(m, 'createdAt', 'created_at');
        _mapField(m, 'updatedAt', 'updated_at');

        if (m['created_at'] == null) {
          m['created_at'] = DateTime.now().toIso8601String();
        }
        if (m['updated_at'] == null) m['updated_at'] = m['created_at'];
        if (m['is_default'] is bool) {
          m['is_default'] = (m['is_default'] as bool) ? 1 : 0;
        }
        return m;
      }).toList();
    }

    // 6. 标准化用户资料 (User Profile)
    if (result.containsKey('user_profile') && result['user_profile'] is Map) {
      final m = Map<String, dynamic>.from(result['user_profile'] as Map);
      _mapField(m, 'avatarPath', 'avatar_path');
      _mapField(m, 'createdAt', 'created_at');
      _mapField(m, 'updatedAt', 'updated_at');

      if (m['weightHistory'] != null) {
        final wh = m.remove('weightHistory');
        m['weight_history'] = wh is List ? jsonEncode(wh) : wh;
      }

      if (m['created_at'] == null) {
        m['created_at'] = DateTime.now().toIso8601String();
      }
      if (m['updated_at'] == null) m['updated_at'] = m['created_at'];
      if (m['id'] == null) m['id'] = 'default';

      result['user_profile'] = m;
    }

    // 7. 标准化 WebDAV 配置
    if (result.containsKey('webdav_config') && result['webdav_config'] is Map) {
      final m = Map<String, dynamic>.from(result['webdav_config'] as Map);
      // 旧架构字段映射
      if (m.containsKey('url') && !m.containsKey('server_url')) {
        m['server_url'] = m.remove('url');
      }
      if (m.containsKey('appPassword') && !m.containsKey('password')) {
        m['password'] = m.remove('appPassword');
      }
      if (m.containsKey('basePath') && !m.containsKey('remote_path')) {
        m['remote_path'] = '/${m.remove('basePath')}/';
      }
      _mapField(m, 'isEnabled', 'auto_sync');
      _mapField(m, 'syncOnLaunch', 'sync_on_launch');
      _mapField(m, 'syncInterval', 'sync_interval');
      if (m['auto_sync'] is bool) {
        m['auto_sync'] = (m['auto_sync'] as bool) ? 1 : 0;
      }
      if (m['created_at'] == null) {
        m['created_at'] = DateTime.now().toIso8601String();
      }
      if (m['updated_at'] == null) m['updated_at'] = m['created_at'];
      if (m['id'] == null) m['id'] = 'default';
      // 移除旧架构的额外字段
      m.remove('apiProxyUrl');
      m.remove('directMode');
      result['webdav_config'] = m;
    }

    return result;
  }

  void _mapField(Map<String, dynamic> m, String oldKey, String newKey) {
    if (m.containsKey(oldKey)) {
      m[newKey] = m.remove(oldKey);
    }
  }

  Future<String> _saveToFile(String content, String fileName) async {
    final dir = await getTemporaryDirectory();
    final file = File(p.join(dir.path, fileName));
    await file.writeAsString(content);
    return file.path;
  }

  Future<void> shareFile(
    String content,
    String fileName, {
    String? subject,
  }) async {
    final filePath = await _saveToFile(content, fileName);
    await Share.shareXFiles([XFile(filePath)], subject: subject ?? 'QNote 导出');
  }

  Future<void> shareMarkdown(String content, String type) async {
    final fileName =
        'qnote_${type}_${DateTime.now().millisecondsSinceEpoch}.md';
    await shareFile(content, fileName, subject: 'QNote $type 导出');
  }

  Future<void> shareJson(String content) async {
    final fileName =
        'qnote_backup_${DateTime.now().millisecondsSinceEpoch}.json';
    await shareFile(content, fileName, subject: 'QNote 数据备份');
  }

  Future<void> applyDeltaFromJson(String jsonString) async {
    final startTime = DateTime.now();
    LoggerService.instance.logImport('开始应用增量变更...');

    final delta = jsonDecode(jsonString) as Map<String, dynamic>;
    final changes = delta['changes'] as Map<String, dynamic>? ?? {};

    if (changes.containsKey('diary_records')) {
      final tableChanges = Map<String, dynamic>.from(changes['diary_records'] as Map);
      final upserts = (tableChanges['upserts'] as List?) ?? [];
      final deletes = (tableChanges['deletes'] as List?) ?? [];
      for (final item in upserts) {
        final map = Map<String, dynamic>.from(item as Map);
        final photosBase64 = map.remove('photos_base64');
        if (photosBase64 is Map) {
          final photoMap = Map<String, dynamic>.from(photosBase64);
          final photos = <String>[];
          for (final entry in photoMap.entries) {
            final savedPath = await _imageRepo.saveBase64Image(
              entry.value as String,
              subfolder: 'diary',
            );
            photos.add(savedPath);
          }
          if (photos.isNotEmpty) {
            map['photos'] = jsonEncode(photos);
          }
        }
        try {
          await _diaryRepo.insert(DiaryRecord.fromMap(map));
        } catch (_) {
          final db = await DatabaseHelper.instance.database;
          await db.update('diary_records', map, where: 'id = ?', whereArgs: [map['id']]);
        }
      }
      for (final id in deletes) {
        try {
          await _diaryRepo.hardDelete(id as String);
        } catch (_) {}
      }
    }

    if (changes.containsKey('notes')) {
      final tableChanges = Map<String, dynamic>.from(changes['notes'] as Map);
      final upserts = (tableChanges['upserts'] as List?) ?? [];
      final deletes = (tableChanges['deletes'] as List?) ?? [];
      for (final item in upserts) {
        final map = Map<String, dynamic>.from(item as Map);
        final imagesBase64 = map.remove('images_base64');
        if (imagesBase64 is Map) {
          final imageMap = Map<String, dynamic>.from(imagesBase64);
          final images = <String>[];
          for (final entry in imageMap.entries) {
            final savedPath = await _imageRepo.saveBase64Image(
              entry.value as String,
              subfolder: 'notes',
            );
            images.add(savedPath);
          }
          if (images.isNotEmpty) {
            map['images'] = jsonEncode(images);
          }
        }
        try {
          await _noteRepo.insert(Note.fromMap(map));
        } catch (_) {
          final db = await DatabaseHelper.instance.database;
          await db.update('notes', map, where: 'id = ?', whereArgs: [map['id']]);
        }
      }
      for (final id in deletes) {
        try {
          await _noteRepo.hardDelete(id as String);
        } catch (_) {}
      }
    }

    if (changes.containsKey('todos')) {
      final tableChanges = Map<String, dynamic>.from(changes['todos'] as Map);
      final upserts = (tableChanges['upserts'] as List?) ?? [];
      final deletes = (tableChanges['deletes'] as List?) ?? [];
      for (final item in upserts) {
        final map = Map<String, dynamic>.from(item as Map);
        try {
          await _todoRepo.insert(Todo.fromMap(map));
        } catch (_) {
          final db = await DatabaseHelper.instance.database;
          await db.update('todos', map, where: 'id = ?', whereArgs: [map['id']]);
        }
      }
      for (final id in deletes) {
        try {
          await _todoRepo.hardDelete(id as String);
        } catch (_) {}
      }
    }

    if (changes.containsKey('folders')) {
      final tableChanges = Map<String, dynamic>.from(changes['folders'] as Map);
      final upserts = (tableChanges['upserts'] as List?) ?? [];
      final deletes = (tableChanges['deletes'] as List?) ?? [];
      for (final item in upserts) {
        final map = Map<String, dynamic>.from(item as Map);
        try {
          await _folderRepo.insert(Folder.fromMap(map));
        } catch (_) {
          final db = await DatabaseHelper.instance.database;
          await db.update('folders', map, where: 'id = ?', whereArgs: [map['id']]);
        }
      }
      for (final id in deletes) {
        try {
          await _folderRepo.delete(id as String);
        } catch (_) {}
      }
    }

    if (changes.containsKey('ai_configs')) {
      final tableChanges = Map<String, dynamic>.from(changes['ai_configs'] as Map);
      final upserts = (tableChanges['upserts'] as List?) ?? [];
      final deletes = (tableChanges['deletes'] as List?) ?? [];
      for (final item in upserts) {
        try {
          await _configRepo.insertAiConfig(AiConfig.fromMap(Map<String, dynamic>.from(item as Map)));
        } catch (_) {
          try {
            await _configRepo.updateAiConfig(AiConfig.fromMap(Map<String, dynamic>.from(item as Map)));
          } catch (_) {}
        }
      }
      for (final id in deletes) {
        try {
          await _configRepo.deleteAiConfig(id as String);
        } catch (_) {}
      }
    }

    if (changes.containsKey('shortcut_configs')) {
      final tableChanges = Map<String, dynamic>.from(changes['shortcut_configs'] as Map);
      final upserts = (tableChanges['upserts'] as List?) ?? [];
      final deletes = (tableChanges['deletes'] as List?) ?? [];
      for (final item in upserts) {
        try {
          await _configRepo.insertShortcutConfig(ShortcutConfig.fromMap(Map<String, dynamic>.from(item as Map)));
        } catch (_) {
          try {
            await _configRepo.updateShortcutConfig(ShortcutConfig.fromMap(Map<String, dynamic>.from(item as Map)));
          } catch (_) {}
        }
      }
      for (final id in deletes) {
        try {
          await _configRepo.deleteShortcutConfig(id as String);
        } catch (_) {}
      }
    }

    if (changes.containsKey('chat_sessions')) {
      final tableChanges = Map<String, dynamic>.from(changes['chat_sessions'] as Map);
      final upserts = (tableChanges['upserts'] as List?) ?? [];
      final deletes = (tableChanges['deletes'] as List?) ?? [];
      for (final item in upserts) {
        try {
          await _configRepo.insertChatSession(ChatSession.fromMap(Map<String, dynamic>.from(item as Map)));
        } catch (_) {
          try {
            await _configRepo.updateChatSession(ChatSession.fromMap(Map<String, dynamic>.from(item as Map)));
          } catch (_) {}
        }
      }
      for (final id in deletes) {
        try {
          await _configRepo.softDeleteChatSession(id as String);
        } catch (_) {}
      }
    }

    if (changes.containsKey('user_profile')) {
      final tableChanges = Map<String, dynamic>.from(changes['user_profile'] as Map);
      final upserts = (tableChanges['upserts'] as List?) ?? [];
      for (final item in upserts) {
        try {
          await _configRepo.upsertUserProfile(UserProfile.fromMap(Map<String, dynamic>.from(item as Map)));
        } catch (_) {}
      }
    }

    if (changes.containsKey('date_color_marks')) {
      final tableChanges = Map<String, dynamic>.from(changes['date_color_marks'] as Map);
      final upserts = (tableChanges['upserts'] as List?) ?? [];
      final deletes = (tableChanges['deletes'] as List?) ?? [];
      for (final item in upserts) {
        try {
          await _colorMarkRepo.insert(DateColorMark.fromMap(Map<String, dynamic>.from(item as Map)));
        } catch (_) {}
      }
      for (final id in deletes) {
        try {
          await _colorMarkRepo.delete(id as String);
        } catch (_) {}
      }
    }

    if (changes.containsKey('body_states')) {
      final tableChanges = Map<String, dynamic>.from(changes['body_states'] as Map);
      final upserts = (tableChanges['upserts'] as List?) ?? [];
      final deletes = (tableChanges['deletes'] as List?) ?? [];
      final db = await DatabaseHelper.instance.database;
      for (final item in upserts) {
        try {
          await db.insert(
            'body_states',
            Map<String, dynamic>.from(item as Map),
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        } catch (_) {}
      }
      for (final id in deletes) {
        try {
          await db.delete('body_states', where: 'id = ?', whereArgs: [id]);
        } catch (_) {}
      }
    }

    if (changes.containsKey('daily_scores')) {
      final tableChanges = Map<String, dynamic>.from(changes['daily_scores'] as Map);
      final upserts = (tableChanges['upserts'] as List?) ?? [];
      final deletes = (tableChanges['deletes'] as List?) ?? [];
      final db = await DatabaseHelper.instance.database;
      for (final item in upserts) {
        try {
          await db.insert(
            'daily_scores',
            Map<String, dynamic>.from(item as Map),
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        } catch (_) {}
      }
      for (final id in deletes) {
        try {
          await db.delete('daily_scores', where: 'id = ?', whereArgs: [id]);
        } catch (_) {}
      }
    }

    if (changes.containsKey('app_configs')) {
      final tableChanges = Map<String, dynamic>.from(changes['app_configs'] as Map);
      final upserts = (tableChanges['upserts'] as List?) ?? [];
      final deletes = (tableChanges['deletes'] as List?) ?? [];
      for (final item in upserts) {
        final map = Map<String, dynamic>.from(item as Map);
        try {
          await _configRepo.setAppConfig(map['key'] as String, map['value'] as String);
        } catch (_) {}
      }
      for (final id in deletes) {
        try {
          await _configRepo.deleteAppConfig(id as String);
        } catch (_) {}
      }
    }

    final duration = DateTime.now().difference(startTime).inMilliseconds;
    LoggerService.instance.logImport('增量变更应用完成', details: '耗时=${duration}ms');
  }
}
