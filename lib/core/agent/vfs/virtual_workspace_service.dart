import 'dart:convert';
import 'package:qnote_flutter/core/agent/skills/skill_registry.dart';
import 'package:qnote_flutter/core/agent/vfs/workspace_event_bus.dart';
import 'package:qnote_flutter/core/storage/config_repository.dart';
import 'package:qnote_flutter/core/storage/diary_repository.dart';
import 'package:qnote_flutter/core/storage/folder_repository.dart';
import 'package:qnote_flutter/core/storage/journal_service.dart';
import 'package:qnote_flutter/core/storage/note_repository.dart';
import 'package:qnote_flutter/core/storage/todo_repository.dart';
import 'package:qnote_flutter/models/diary_record.dart';
import 'package:qnote_flutter/models/folder.dart';
import 'package:qnote_flutter/models/note.dart';
import 'package:qnote_flutter/models/todo.dart';
import 'package:qnote_flutter/models/user_profile.dart';
import 'package:qnote_flutter/models/webdav_config.dart';
import 'package:uuid/uuid.dart';

/// 虚拟文件系统 (VFS) 服务：将 QNote 的 SQLite 实体透明抽象为文件和目录
class VirtualWorkspaceService {
  static final VirtualWorkspaceService instance = VirtualWorkspaceService._();
  VirtualWorkspaceService._();

  final TodoRepository _todoRepo = TodoRepository();
  final FolderRepository _folderRepo = FolderRepository();
  final NoteRepository _noteRepo = NoteRepository();
  final DiaryRepository _diaryRepo = DiaryRepository();
  final JournalService _journalService = JournalService.instance;
  final ConfigRepository _configRepo = ConfigRepository.instance;
  final SkillRegistry _skillRegistry = SkillRegistry.instance;

  static const String agentsDoc = '''# QNote Agent Operating System (AGENTS.md)

欢迎来到 QNote 虚拟工作区。你是智能管家与个人系统助手【小Q】。
在你的运行环境中，QNote 的所有数据统一抽象在根目录 `/` 下的虚拟文件系统中。

## 1. 虚拟文件系统结构
- `/AGENTS.md`: 本工作区指南与系统说明（只读）。
- `/skills/`: 专业技能手册库（查阅对应领域的规范与操作手册）。
- `/todos/`: 待办事项库（目录名对应分类，如 `/todos/今日/`、`/todos/长期/`、`/todos/工作/`）。
- `/notes/`: 笔记与知识库（目录名对应笔记本，如 `/notes/技术架构/`、`/notes/读书笔记/`）。
- `/timeline/`: 时间线流水日志（按日期归档，如 `/timeline/2026-09-11.md`）。
- `/journal/`: 每日深度长篇日记与复盘（如 `/journal/2026-09-11.md`）。
- `/settings/`: 系统偏好与配置（JSON 文件，如 `profile.json`、`webdav.json`）。

## 2. 核心行为准则
1. **像工程师一样自主探索**：优先使用 `list_dir` 查看目录结构，使用 `read_file` 查阅详情，使用 `write_file` 或 `edit_file` 执行变更。
2. **严禁凭空口头承诺**：必须通过实际的文件系统工具调用执行成功后，再向用户汇报结果！
3. **查阅 Skill 手册**：在处理待办规划、笔记重排、时间打卡等专业任务时，通过 `read_file(path: "/skills/<skill-name>.md")` 或 `skill(name: "...")` 查阅标准作业程序。
''';

  /// 规范化路径
  String normalizePath(String path) {
    var p = path.trim().replaceAll(r'\', '/');
    if (!p.startsWith('/')) {
      p = '/$p';
    }
    // 移除多余的连续斜杠
    p = p.replaceAll(RegExp(r'/+'), '/');
    return p;
  }

  // ==========================================
  // 1. listDir: 列出目录内容
  // ==========================================
  Future<List<String>> listDir(String rawPath, {bool recursive = false}) async {
    final path = normalizePath(rawPath);

    if (path == '/' || path.isEmpty) {
      return [
        'AGENTS.md',
        'skills/',
        'todos/',
        'notes/',
        'timeline/',
        'journal/',
        'settings/',
      ];
    }

    if (path == '/skills' || path == '/skills/') {
      return _skillRegistry.listSkills().map((s) => '${s['name']}.md').toList();
    }

    if (path == '/settings' || path == '/settings/') {
      return ['profile.json', 'webdav.json', 'shortcuts.json'];
    }

    // 1. /todos 目录
    if (path == '/todos' || path == '/todos/') {
      final folders = await _folderRepo.getByType('todo');
      final result = <String>[];
      for (final f in folders) {
        result.add('${f.name}/');
      }
      if (!result.contains('今日/')) result.insert(0, '今日/');
      if (!result.contains('长期/')) result.add('长期/');
      return result;
    }

    if (path.startsWith('/todos/')) {
      final folderName = path.substring('/todos/'.length).replaceAll('/', '').trim();
      final todos = await _todoRepo.getAll();
      final folders = await _folderRepo.getByType('todo');
      final matchedFolder = folders.where((f) => f.name.trim() == folderName).firstOrNull;

      final matchedTodos = todos.where((t) {
        if (matchedFolder != null) {
          if (t.folderId == matchedFolder.id) return true;
        }
        // 若为今日，容错兜底未分类且非长期待办
        if (folderName == '今日' && (t.folderId == null || t.folderId!.isEmpty || t.folderId == 'todo_default_today') && !t.isLongTerm) {
          return true;
        }
        // 若为长期，容错兜底未分类长期待办
        if (folderName == '长期' && (t.folderId == 'todo_default_longterm' || (t.isLongTerm && (t.folderId == null || t.folderId!.isEmpty)))) {
          return true;
        }
        return false;
      }).toList();

      return matchedTodos.map((t) {
        final prefix = t.isCompleted ? '[x] ' : '[ ] ';
        return '$prefix${t.title.trim().isEmpty ? "未命名待办" : t.title}.md';
      }).toList();
    }

    // 2. /notes 目录
    if (path == '/notes' || path == '/notes/') {
      final folders = await _folderRepo.getByType('note');
      final notes = await _noteRepo.getAll();
      final result = <String>[];
      for (final f in folders) {
        result.add('${f.name}/');
      }
      final rootNotes = notes.where((n) => n.folderId == null || n.folderId!.isEmpty).toList();
      for (final n in rootNotes) {
        result.add('${n.title.trim().isEmpty ? "未命名笔记" : n.title}.md');
      }
      return result;
    }

    if (path.startsWith('/notes/')) {
      final folderName = path.substring('/notes/'.length).replaceAll('/', '').trim();
      final folders = await _folderRepo.getByType('note');
      final matchedFolder = folders.where((f) => f.name.trim() == folderName).firstOrNull;
      if (matchedFolder == null) return [];

      final notes = await _noteRepo.getAll();
      final folderNotes = notes.where((n) => n.folderId == matchedFolder.id).toList();
      return folderNotes.map((n) => '${n.title.trim().isEmpty ? "未命名笔记" : n.title}.md').toList();
    }

    // 3. /timeline 目录
    if (path == '/timeline' || path == '/timeline/') {
      final now = DateTime.now();
      final dates = <String>[];
      for (int i = 0; i < 7; i++) {
        final d = now.subtract(Duration(days: i));
        final dateStr = '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
        dates.add('$dateStr.md');
      }
      return dates;
    }

    // 4. /journal 目录
    if (path == '/journal' || path == '/journal/') {
      final now = DateTime.now();
      final dates = <String>[];
      for (int i = 0; i < 7; i++) {
        final d = now.subtract(Duration(days: i));
        final dateStr = '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
        dates.add('$dateStr.md');
      }
      return dates;
    }

    return [];
  }

  // ==========================================
  // 2. readFile: 读取虚拟文件
  // ==========================================
  Future<String> readFile(String rawPath, {int? offset, int? limit}) async {
    final path = normalizePath(rawPath);
    String fullContent = '';

    if (path == '/AGENTS.md') {
      fullContent = agentsDoc;
    } else if (path.startsWith('/skills/')) {
      final skillDoc = _skillRegistry.getSkillContent(path);
      if (skillDoc == null) {
        throw Exception('找不到技能手册: $path。可用技能请查看 /skills/');
      }
      fullContent = skillDoc;
    } else if (path.startsWith('/todos/')) {
      fullContent = await _readTodoFile(path);
    } else if (path.startsWith('/notes/')) {
      fullContent = await _readNoteFile(path);
    } else if (path.startsWith('/timeline/')) {
      fullContent = await _readTimelineFile(path);
    } else if (path.startsWith('/journal/')) {
      fullContent = await _readJournalFile(path);
    } else if (path.startsWith('/settings/')) {
      fullContent = await _readSettingsFile(path);
    } else {
      throw Exception('未知的文件路径: $path');
    }

    // 处理行切片
    final lines = fullContent.split('\n');
    final start = (offset != null && offset > 0) ? (offset - 1).clamp(0, lines.length) : 0;
    final end = (limit != null && limit > 0) ? (start + limit).clamp(0, lines.length) : lines.length;

    final slicedLines = lines.sublist(start, end);
    final buffer = StringBuffer();
    for (int i = 0; i < slicedLines.length; i++) {
      final lineNum = start + i + 1;
      buffer.writeln('$lineNum\t${slicedLines[i]}');
    }
    return buffer.toString().trimRight();
  }

  Future<String> _readTodoFile(String path) async {
    final segments = path.substring('/todos/'.length).split('/');
    final String titleWithExt = segments.length >= 2 ? segments.sublist(1).join('/') : segments[0];
    final rawTitle = titleWithExt.replaceAll('.md', '').replaceAll(RegExp(r'^\[[ x]\]\s*'), '').trim();

    final allTodos = await _todoRepo.getAll();
    Todo? matched;
    // 优先根据 id 精确匹配
    matched = allTodos.where((t) => t.id == rawTitle).firstOrNull;
    // 其次按标题与分类匹配
    matched ??= allTodos.where((t) {
      if (t.title.trim() != rawTitle) return false;
      return true;
    }).firstOrNull;

    if (matched == null) {
      throw Exception('待办文件不存在: $path');
    }

    final buffer = StringBuffer();
    buffer.writeln('---');
    buffer.writeln('id: "${matched.id}"');
    buffer.writeln('title: "${matched.title}"');
    buffer.writeln('status: ${matched.isCompleted ? "completed" : "pending"}');
    buffer.writeln('priority: ${matched.priority}');
    if (matched.dueDate != null) {
      buffer.writeln('due_date: "${matched.dueDate!.toIso8601String()}"');
    }
    buffer.writeln('is_long_term: ${matched.isLongTerm}');
    buffer.writeln('---');
    if (matched.description.isNotEmpty) {
      buffer.writeln(matched.description);
    }
    return buffer.toString();
  }

  Future<String> _readNoteFile(String path) async {
    final segments = path.substring('/notes/'.length).split('/');
    final rawTitle = segments.last.replaceAll('.md', '').trim();

    final allNotes = await _noteRepo.getAll();
    Note? matched = allNotes.where((n) => n.id == rawTitle).firstOrNull;
    matched ??= allNotes.where((n) => n.title.trim() == rawTitle).firstOrNull;

    if (matched == null) {
      throw Exception('笔记文件不存在: $path');
    }

    final buffer = StringBuffer();
    buffer.writeln('---');
    buffer.writeln('id: "${matched.id}"');
    buffer.writeln('title: "${matched.title}"');
    buffer.writeln('tags: ${jsonEncode(matched.tags)}');
    buffer.writeln('pinned: ${matched.isPinned}');
    buffer.writeln('created_at: "${matched.createdAt.toIso8601String()}"');
    buffer.writeln('updated_at: "${matched.updatedAt.toIso8601String()}"');
    buffer.writeln('---');
    buffer.writeln(matched.content);
    return buffer.toString();
  }

  Future<String> _readTimelineFile(String path) async {
    final dateStr = path.substring('/timeline/'.length).replaceAll('.md', '').trim();
    DateTime date;
    try {
      date = DateTime.parse(dateStr);
    } catch (_) {
      date = DateTime.now();
    }

    final records = await _diaryRepo.getByDate(date);
    records.sort((a, b) => a.time.compareTo(b.time));

    final buffer = StringBuffer();
    buffer.writeln('# $dateStr 时间线流水');
    buffer.writeln();
    if (records.isEmpty) {
      buffer.writeln('> 暂无流水事件打卡。可以通过 write_file 追加事件。');
      return buffer.toString();
    }

    for (final r in records) {
      final timeStr = '${r.time.hour.toString().padLeft(2, '0')}:${r.time.minute.toString().padLeft(2, '0')}';
      buffer.writeln('## [$timeStr] ${r.title} <!-- id: ${r.id} -->');
      buffer.writeln('- 分类: ${r.displayTag}');
      buffer.writeln('- 心情: ${r.mood}');
      if (r.content.isNotEmpty) {
        buffer.writeln('- 详情: ${r.content}');
      }
      buffer.writeln();
    }
    return buffer.toString().trimRight();
  }

  Future<String> _readJournalFile(String path) async {
    final dateStr = path.substring('/journal/'.length).replaceAll('.md', '').trim();
    DateTime date;
    try {
      date = DateTime.parse(dateStr);
    } catch (_) {
      date = DateTime.now();
    }
    final note = await _journalService.getNoteForDate(date);
    return note?.content ?? '# $dateStr 日记\n\n> 尚未开始编写这天的深度反思日记。';
  }

  Future<String> _readSettingsFile(String path) async {
    final name = path.substring('/settings/'.length).trim();
    if (name == 'profile.json') {
      final profile = await _configRepo.getUserProfile();
      return const JsonEncoder.withIndent('  ').convert(profile?.toMap() ?? {'name': 'QNote 用户'});
    } else if (name == 'webdav.json') {
      final webdav = await _configRepo.getWebdavConfig();
      return const JsonEncoder.withIndent('  ').convert(webdav?.toMap() ?? {'enabled': false});
    } else if (name == 'shortcuts.json') {
      final shortcuts = await _configRepo.getAllShortcutConfigs();
      return const JsonEncoder.withIndent('  ').convert(shortcuts.map((s) => s.toMap()).toList());
    }
    throw Exception('未知的配置文件: $path');
  }

  // ==========================================
  // 3. writeFile: 写入/新建虚拟文件
  // ==========================================
  Future<Map<String, dynamic>> writeFile(String rawPath, String content) async {
    final path = normalizePath(rawPath);

    if (path.startsWith('/todos/')) {
      return await _writeTodoFile(path, content);
    } else if (path.startsWith('/notes/')) {
      return await _writeNoteFile(path, content);
    } else if (path.startsWith('/timeline/')) {
      return await _writeTimelineFile(path, content);
    } else if (path.startsWith('/journal/')) {
      return await _writeJournalFile(path, content);
    } else if (path.startsWith('/settings/')) {
      return await _writeSettingsFile(path, content);
    }
    throw Exception('不支持写入只读或未知的路径: $path');
  }

  Future<Map<String, dynamic>> _writeTodoFile(String path, String content) async {
    final segments = path.substring('/todos/'.length).split('/');
    String folderName = '今日';
    String titleWithExt = '';
    if (segments.length >= 2) {
      folderName = segments[0].trim();
      titleWithExt = segments.sublist(1).join('/');
    } else {
      titleWithExt = segments[0];
    }
    final title = titleWithExt.replaceAll('.md', '').replaceAll(RegExp(r'^\[[ x]\]\s*'), '').trim();

    // 1. 解析 Frontmatter
    final parsed = _parseFrontmatter(content);
    final meta = parsed.meta;
    final description = parsed.body.trim();

    final status = (meta['status'] as String? ?? '').toLowerCase();
    final isCompleted = status == 'completed' || status == 'done' || path.contains('[x]');
    final rawPriority = (meta['priority'] as String? ?? 'normal').toLowerCase();
    final priority = (rawPriority == 'important' || rawPriority == 'high') ? 'important' : 'normal';
    final isLongTerm = meta['is_long_term'] == true || folderName == '长期';

    DateTime? dueDate;
    if (meta['due_date'] != null) {
      try {
        dueDate = DateTime.parse(meta['due_date'].toString().replaceAll('"', ''));
      } catch (_) {}
    }

    // 2. 解析或自动创建分类
    final folderId = await _resolveTodoFolder(folderName, isLongTerm: isLongTerm);

    // 3. 判断是更新还是创建
    final allTodos = await _todoRepo.getAll();
    final existingId = meta['id']?.toString().replaceAll('"', '');
    Todo? existing;
    if (existingId != null && existingId.isNotEmpty) {
      existing = allTodos.where((t) => t.id == existingId).firstOrNull;
    }
    existing ??= allTodos.where((t) => t.title.trim() == title && t.folderId == folderId).firstOrNull;

    final now = DateTime.now();
    if (existing != null) {
      final updated = existing.copyWith(
        title: title.isNotEmpty ? title : existing.title,
        description: description,
        isCompleted: isCompleted,
        priority: priority,
        dueDate: dueDate ?? existing.dueDate,
        folderId: folderId,
        isLongTerm: isLongTerm,
        updatedAt: now,
      );
      await _todoRepo.update(updated);
      WorkspaceEventBus.instance.emit(path, WorkspaceChangeType.updated, updated);
      return {
        'status': 'updated',
        'path': path,
        'id': updated.id,
        'title': updated.title,
        'folder': folderName,
        'folder_id': folderId,
        'is_completed': updated.isCompleted,
      };
    } else {
      final newTodo = Todo(
        id: const Uuid().v4(),
        title: title,
        description: description,
        isCompleted: isCompleted,
        priority: priority,
        dueDate: dueDate,
        folderId: folderId,
        isLongTerm: isLongTerm,
        sortOrder: now.millisecondsSinceEpoch,
        createdAt: now,
        updatedAt: now,
      );
      await _todoRepo.insert(newTodo);
      WorkspaceEventBus.instance.emit(path, WorkspaceChangeType.created, newTodo);
      return {
        'status': 'created',
        'path': path,
        'id': newTodo.id,
        'title': newTodo.title,
        'folder': folderName,
        'folder_id': folderId,
        'is_completed': newTodo.isCompleted,
      };
    }
  }

  Future<String> _resolveTodoFolder(String folderName, {bool isLongTerm = false}) async {
    final folders = await _folderRepo.getByType('todo');
    final trimmed = folderName.trim();

    if (trimmed == '今日' || trimmed == 'today') {
      final today = folders.where((f) => f.id == 'todo_default_today' || f.name == '今日').firstOrNull;
      if (today != null) return today.id;
    }
    if (trimmed == '长期' || trimmed == 'longterm' || isLongTerm) {
      final longterm = folders.where((f) => f.id == 'todo_default_longterm' || f.name == '长期').firstOrNull;
      if (longterm != null) return longterm.id;
    }

    final matched = folders.where((f) => f.name.toLowerCase() == trimmed.toLowerCase()).firstOrNull;
    if (matched != null) return matched.id;

    // 不存在则自动新建待办分类
    final now = DateTime.now();
    final newFolder = Folder(
      id: const Uuid().v4(),
      name: trimmed,
      type: 'todo',
      sortOrder: folders.length,
      createdAt: now,
      updatedAt: now,
    );
    await _folderRepo.insert(newFolder);
    return newFolder.id;
  }

  Future<Map<String, dynamic>> _writeNoteFile(String path, String content) async {
    final segments = path.substring('/notes/'.length).split('/');
    String? folderName;
    String titleWithExt;
    if (segments.length >= 2) {
      folderName = segments[0].trim();
      titleWithExt = segments.sublist(1).join('/');
    } else {
      titleWithExt = segments[0];
    }
    final title = titleWithExt.replaceAll('.md', '').trim();

    final parsed = _parseFrontmatter(content);
    final meta = parsed.meta;
    final noteContent = parsed.body;

    String? folderId;
    if (folderName != null && folderName.isNotEmpty) {
      final noteFolders = await _folderRepo.getByType('note');
      var matched = noteFolders.where((f) => f.name == folderName).firstOrNull;
      if (matched == null) {
        final now = DateTime.now();
        matched = Folder(
          id: const Uuid().v4(),
          name: folderName,
          type: 'note',
          sortOrder: noteFolders.length,
          createdAt: now,
          updatedAt: now,
        );
        await _folderRepo.insert(matched);
      }
      folderId = matched.id;
    }

    final allNotes = await _noteRepo.getAll();
    final existingId = meta['id']?.toString().replaceAll('"', '');
    Note? existing;
    if (existingId != null) {
      existing = allNotes.where((n) => n.id == existingId).firstOrNull;
    }
    existing ??= allNotes.where((n) => n.title.trim() == title && n.folderId == folderId).firstOrNull;

    final tagsStr = meta['tags'] is List
        ? (meta['tags'] as List).join(', ')
        : (meta['tags']?.toString() ?? '');

    final now = DateTime.now();
    if (existing != null) {
      final updated = existing.copyWith(
        title: title.isNotEmpty ? title : existing.title,
        content: noteContent,
        folderId: folderId ?? existing.folderId,
        isPinned: meta['pinned'] == true,
        tags: tagsStr.isNotEmpty ? tagsStr : existing.tags,
        updatedAt: now,
      );
      await _noteRepo.update(updated);
      WorkspaceEventBus.instance.emit(path, WorkspaceChangeType.updated, updated);
      return {'status': 'updated', 'path': path, 'id': updated.id, 'title': updated.title};
    } else {
      final newNote = Note(
        id: const Uuid().v4(),
        title: title,
        content: noteContent,
        folderId: folderId,
        isPinned: meta['pinned'] == true,
        tags: tagsStr,
        createdAt: now,
        updatedAt: now,
      );
      await _noteRepo.insert(newNote);
      WorkspaceEventBus.instance.emit(path, WorkspaceChangeType.created, newNote);
      return {'status': 'created', 'path': path, 'id': newNote.id, 'title': newNote.title};
    }
  }

  Future<Map<String, dynamic>> _writeTimelineFile(String path, String content) async {
    final dateStr = path.substring('/timeline/'.length).replaceAll('.md', '').trim();
    DateTime baseDate;
    try {
      baseDate = DateTime.parse(dateStr);
    } catch (_) {
      baseDate = DateTime.now();
    }

    // 解析 markdown 块
    final blockRegex = RegExp(r'##\s*\[(\d{1,2}:\d{2})\]\s*([^\n]+)(?:<!--\s*id:\s*([^\s>]+)\s*-->)?([\s\S]*?)(?=(?:##\s*\[|\Z))');
    final matches = blockRegex.allMatches(content);

    int count = 0;
    for (final m in matches) {
      final timeStr = m.group(1)!.trim();
      final title = m.group(2)!.replaceAll(RegExp(r'<!--.*?-->'), '').trim();
      final recordId = m.group(3)?.trim();
      final body = m.group(4)?.trim() ?? '';

      final timeParts = timeStr.split(':');
      final recordTime = DateTime(
        baseDate.year,
        baseDate.month,
        baseDate.day,
        int.parse(timeParts[0]),
        int.parse(timeParts[1]),
      );

      String category = '日常';
      int? mood;
      String detail = '';

      for (final line in body.split('\n')) {
        final l = line.trim();
        if (l.startsWith('- 分类:') || l.startsWith('- category:')) {
          category = l.split(':')[1].trim();
        } else if (l.startsWith('- 心情:') || l.startsWith('- mood:')) {
          mood = int.tryParse(l.split(':')[1].trim());
        } else if (l.startsWith('- 详情:') || l.startsWith('- detail:')) {
          detail = l.split(':')[1].trim();
        } else if (l.isNotEmpty && !l.startsWith('-')) {
          detail += (detail.isEmpty ? '' : '\n') + l;
        }
      }

      final now = DateTime.now();
      if (recordId != null && recordId.isNotEmpty) {
        final existing = await _diaryRepo.getById(recordId);
        if (existing != null) {
          final updated = existing.copyWith(
            title: title,
            content: detail,
            displayTag: category,
            time: recordTime,
            mood: mood ?? existing.mood,
            updatedAt: now,
          );
          await _diaryRepo.update(updated);
          count++;
          continue;
        }
      }

      final newRecord = DiaryRecord(
        id: const Uuid().v4(),
        title: title,
        content: detail,
        displayTag: category,
        time: recordTime,
        mood: mood ?? 3,
        createdAt: now,
        updatedAt: now,
      );
      await _diaryRepo.insert(newRecord);
      count++;
    }

    WorkspaceEventBus.instance.emit(path, WorkspaceChangeType.updated, {'date': dateStr, 'count': count});
    return {'status': 'success', 'path': path, 'records_processed': count};
  }

  Future<Map<String, dynamic>> _writeJournalFile(String path, String content) async {
    final dateStr = path.substring('/journal/'.length).replaceAll('.md', '').trim();
    DateTime date;
    try {
      date = DateTime.parse(dateStr);
    } catch (_) {
      date = DateTime.now();
    }
    await _journalService.saveJournal(date, content);
    WorkspaceEventBus.instance.emit(path, WorkspaceChangeType.updated, {'date': dateStr});
    return {'status': 'saved', 'path': path, 'date': dateStr};
  }

  Future<Map<String, dynamic>> _writeSettingsFile(String path, String content) async {
    final name = path.substring('/settings/'.length).trim();
    final jsonMap = jsonDecode(content) as Map<String, dynamic>;

    if (name == 'profile.json') {
      final profile = UserProfile.fromMap(jsonMap);
      await _configRepo.saveUserProfile(profile);
      WorkspaceEventBus.instance.emit(path, WorkspaceChangeType.updated, profile);
      return {'status': 'updated', 'path': path};
    } else if (name == 'webdav.json') {
      final webdav = WebdavConfig.fromMap(jsonMap);
      await _configRepo.upsertWebdavConfig(webdav);
      WorkspaceEventBus.instance.emit(path, WorkspaceChangeType.updated, webdav);
      return {'status': 'updated', 'path': path};
    }
    throw Exception('不支持修改此配置: $path');
  }

  // ==========================================
  // 4. editFile: 精准文本替换
  // ==========================================
  Future<Map<String, dynamic>> editFile(
    String rawPath,
    String oldText,
    String newText, {
    bool replaceAll = false,
  }) async {
    final path = normalizePath(rawPath);
    final rawLines = (await readFile(path)).split('\n');
    // 去掉行号前缀
    final originalContent = rawLines.map((l) {
      final tabIdx = l.indexOf('\t');
      return tabIdx != -1 ? l.substring(tabIdx + 1) : l;
    }).join('\n');

    if (!originalContent.contains(oldText)) {
      throw Exception('在文件 $path 中未找到要替换的文本:\n$oldText');
    }

    final newContent = replaceAll
        ? originalContent.replaceAll(oldText, newText)
        : originalContent.replaceFirst(oldText, newText);

    return await writeFile(path, newContent);
  }

  // ==========================================
  // 5. deleteFile: 删除文件
  // ==========================================
  Future<Map<String, dynamic>> deleteFile(String rawPath) async {
    final path = normalizePath(rawPath);

    if (path.startsWith('/todos/')) {
      final segments = path.substring('/todos/'.length).split('/');
      final rawTitle = segments.last.replaceAll('.md', '').replaceAll(RegExp(r'^\[[ x]\]\s*'), '').trim();
      final allTodos = await _todoRepo.getAll();
      final matched = allTodos.where((t) => t.id == rawTitle || t.title.trim() == rawTitle).firstOrNull;
      if (matched != null) {
        await _todoRepo.softDelete(matched.id);
        WorkspaceEventBus.instance.emit(path, WorkspaceChangeType.deleted, matched);
        return {'status': 'deleted', 'path': path, 'id': matched.id, 'title': matched.title};
      }
      throw Exception('未找到要删除的待办: $path');
    }

    if (path.startsWith('/notes/')) {
      final segments = path.substring('/notes/'.length).split('/');
      final rawTitle = segments.last.replaceAll('.md', '').trim();
      final allNotes = await _noteRepo.getAll();
      final matched = allNotes.where((n) => n.id == rawTitle || n.title.trim() == rawTitle).firstOrNull;
      if (matched != null) {
        await _noteRepo.softDelete(matched.id);
        WorkspaceEventBus.instance.emit(path, WorkspaceChangeType.deleted, matched);
        return {'status': 'deleted', 'path': path, 'id': matched.id, 'title': matched.title};
      }
      throw Exception('未找到要删除的笔记: $path');
    }

    throw Exception('当前路径不支持直接删除: $path');
  }

  // ==========================================
  // 6. grep: 全局检索
  // ==========================================
  Future<List<Map<String, dynamic>>> grep(String query, {String rootPath = '/'}) async {
    final results = <Map<String, dynamic>>[];
    final reg = RegExp(query, caseSensitive: false);

    // 检索 todos
    final todos = await _todoRepo.getAll();
    final folders = await _folderRepo.getByType('todo');
    final folderMap = {for (final f in folders) f.id: f.name};

    for (final t in todos) {
      final folderName = folderMap[t.folderId] ?? (t.isLongTerm ? '长期' : '今日');
      final path = '/todos/$folderName/${t.title}.md';
      if (reg.hasMatch(t.title) || reg.hasMatch(t.description)) {
        results.add({
          'path': path,
          'line': 1,
          'match': t.title,
          'type': 'todo',
          'is_completed': t.isCompleted,
        });
      }
    }

    // 检索 notes
    final notes = await _noteRepo.getAll();
    for (final n in notes) {
      final path = '/notes/${n.title}.md';
      if (reg.hasMatch(n.title) || reg.hasMatch(n.content)) {
        results.add({
          'path': path,
          'line': 1,
          'match': n.title,
          'type': 'note',
        });
      }
    }

    return results;
  }

  /// 辅助方法：解析 Frontmatter
  _ParsedContent _parseFrontmatter(String content) {
    if (!content.startsWith('---')) {
      return _ParsedContent(meta: {}, body: content);
    }
    final secondDash = content.indexOf('---', 3);
    if (secondDash == -1) {
      return _ParsedContent(meta: {}, body: content);
    }

    final header = content.substring(3, secondDash).trim();
    final body = content.substring(secondDash + 3).trim();

    final meta = <String, dynamic>{};
    for (final line in header.split('\n')) {
      final colon = line.indexOf(':');
      if (colon != -1) {
        final key = line.substring(0, colon).trim();
        var val = line.substring(colon + 1).trim();
        if (val.startsWith('"') && val.endsWith('"') && val.length >= 2) {
          val = val.substring(1, val.length - 1);
        }
        if (val == 'true') {
          meta[key] = true;
        } else if (val == 'false') {
          meta[key] = false;
        } else {
          meta[key] = val;
        }
      }
    }
    return _ParsedContent(meta: meta, body: body);
  }
}

class _ParsedContent {
  final Map<String, dynamic> meta;
  final String body;
  _ParsedContent({required this.meta, required this.body});
}
