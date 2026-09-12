import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:qnote_flutter/core/agent/skills/skill_registry.dart';
import 'package:qnote_flutter/core/agent/vfs/workspace_event_bus.dart';
import 'package:qnote_flutter/core/agent/vfs/workspace_undo_entry.dart';
import 'package:qnote_flutter/core/ai/free_model_service.dart';
import 'package:qnote_flutter/core/notification/notification_service.dart';
import 'package:qnote_flutter/core/storage/color_mark_repository.dart';
import 'package:qnote_flutter/core/storage/config_repository.dart';
import 'package:qnote_flutter/core/storage/daily_score_repository.dart';
import 'package:qnote_flutter/core/storage/diary_repository.dart';
import 'package:qnote_flutter/core/storage/fixed_event_repository.dart';
import 'package:qnote_flutter/core/storage/folder_repository.dart';
import 'package:qnote_flutter/core/storage/journal_service.dart';
import 'package:qnote_flutter/core/storage/note_repository.dart';
import 'package:qnote_flutter/core/storage/todo_repository.dart';
import 'package:qnote_flutter/core/utils/reminder_utils.dart';
import 'package:qnote_flutter/models/agent_memory.dart';
import 'package:qnote_flutter/models/ai_config.dart';
import 'package:qnote_flutter/models/ai_roles.dart';
import 'package:qnote_flutter/models/chat_session.dart';
import 'package:qnote_flutter/models/date_color_mark.dart';
import 'package:qnote_flutter/models/diary_record.dart';
import 'package:qnote_flutter/models/fixed_event_template.dart';
import 'package:qnote_flutter/models/folder.dart';
import 'package:qnote_flutter/models/note.dart';
import 'package:qnote_flutter/models/shortcut_config.dart';
import 'package:qnote_flutter/models/tag_entry.dart';
import 'package:qnote_flutter/models/todo.dart';
import 'package:qnote_flutter/models/user_profile.dart';
import 'package:qnote_flutter/models/webdav_config.dart';
import 'package:qnote_flutter/models/weight_record.dart';
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
  final DailyScoreRepository _dailyScoreRepo = DailyScoreRepository();
  final ColorMarkRepository _colorMarkRepo = ColorMarkRepository();
  final SkillRegistry _skillRegistry = SkillRegistry.instance;

  // ==========================================
  // 变更录制（对话轮次级撤销快照，支撑小Q对话的撤回/再次编辑）
  // ==========================================
  /// 录制句柄 → 该任务捕获的变更缓冲；句柄制使 AI 主会话与悬浮小Q任务可并发录制互不污染
  final Map<int, List<WorkspaceUndoEntry>> _recorders = {};
  int _recorderSeq = 0;

  /// 可录制的业务路径前缀；/chats/ 涉及会话自身（撤回时消息正在截断落库），跳过录制
  static const List<String> _recordablePrefixes = [
    '/todos/',
    '/notes/',
    '/timeline/',
    '/journal/',
    '/settings/',
    '/folders/',
    '/memory/',
  ];

  /// 开始录制一轮对话的 VFS 变更：捕获每个路径被本轮首次修改前的旧状态。
  /// 返回录制句柄，交由 [stopRecording] 结束录制（支持多任务并发录制）
  int startRecording() {
    final handle = _recorderSeq++;
    _recorders[handle] = [];
    return handle;
  }

  /// 结束录制并返回该句柄捕获的变更条目（同一归一化路径只保留首次、即最旧的状态）
  List<WorkspaceUndoEntry> stopRecording(int handle) {
    return _recorders.remove(handle) ?? <WorkspaceUndoEntry>[];
  }

  /// 录制中则捕获指定路径修改前的旧状态；捕获失败静默跳过，绝不阻断正常写操作
  Future<void> _captureUndoState(String rawPath) async {
    if (_recorders.isEmpty) return;

    String path;
    try {
      path = normalizePath(rawPath);
    } catch (_) {
      return;
    }

    if (!_recordablePrefixes.any(path.startsWith)) return;

    // 捕获路径统一规范化，保证同一实体在一轮内多次操作（先按标题写入、又被目录连坐删除
    // 按 id 捕获）只保留最旧快照：
    // - timeline 单条路径读写解析不了日期会误落到"今天"，归一化到天文件
    // - 待办/笔记以实体 id 为键（待办需携带原分类名，写回时才能落回原分类）
    if (path.startsWith('/timeline/')) {
      final resolved = await _resolveTimelineDayPath(path);
      if (resolved == null) return;
      path = resolved;
    } else if (path.startsWith('/todos/')) {
      path = await _canonicalTodoPath(path) ?? path;
    } else if (path.startsWith('/notes/')) {
      path = await _canonicalNotePath(path) ?? path;
    }

    WorkspaceUndoEntry? entry;
    for (final buffer in _recorders.values) {
      if (buffer.any((e) => e.path == path)) continue;
      // 各录制缓冲的去重独立进行：首个需要该路径快照的缓冲触发一次捕获即可
      entry ??= await _buildUndoEntry(path);
      if (entry == null) return;
      buffer.add(entry);
    }
  }

  /// 构建指定路径修改前的撤销快照；路径读取异常时按"本轮前不存在"处理
  Future<WorkspaceUndoEntry?> _buildUndoEntry(String path) async {
    // 日记的空态读取不抛错而是返回占位文案，需单独判定真实存在性
    if (path.startsWith('/journal/')) {
      try {
        final dateStr = path.substring('/journal/'.length).replaceAll('.md', '').trim();
        final date = DateTime.parse(dateStr);
        final existing = await _journalService.getNoteForDate(date);
        return WorkspaceUndoEntry(
          path: path,
          existedBefore: existing != null && existing.content.trim().isNotEmpty,
          beforeContent: (existing != null && existing.content.trim().isNotEmpty)
              ? existing.content
              : null,
        );
      } catch (_) {
        return WorkspaceUndoEntry(path: path, existedBefore: false);
      }
    }

    // 小Q记忆的空态读取不抛错而是返回占位文案，需按真实存储判定存在性
    if (path.startsWith('/memory/')) {
      final category = AgentMemoryCategory.fromPath(path);
      if (category == null) {
        return WorkspaceUndoEntry(path: path, existedBefore: false);
      }
      try {
        final doc = await _configRepo.getAgentMemory(category);
        final hasContent = doc.content.trim().isNotEmpty;
        return WorkspaceUndoEntry(
          path: path,
          existedBefore: hasContent,
          beforeContent: hasContent ? doc.content : null,
        );
      } catch (_) {
        return WorkspaceUndoEntry(path: path, existedBefore: false);
      }
    }

    try {
      final raw = await readFile(path);
      // 剥离 readFile 输出的行号前缀，恢复时可直接作为 writeFile 输入完成回写
      final before = raw
          .split('\n')
          .map((l) => l.replaceFirst(RegExp(r'^\d+\t'), ''))
          .join('\n');
      // 时间线空天文件的占位文案写回会被差量逻辑拒绝，按"本轮前不存在"处理
      final isEmptyTimeline =
          path.startsWith('/timeline/') && before.contains('暂无流水事件打卡');
      return WorkspaceUndoEntry(
        path: path,
        existedBefore: !isEmptyTimeline,
        beforeContent: isEmptyTimeline ? null : before,
      );
    } catch (_) {
      return WorkspaceUndoEntry(path: path, existedBefore: false);
    }
  }

  // ==========================================
  // 页面上下文路径解析（全局悬浮小Q快捷入口提示 Agent 精确操作目标用）
  // 复用录制捕获的归一化逻辑，保证提示路径与 undo 快照路径一致
  // ==========================================
  /// 解析笔记实体的规范虚拟路径（`/notes/<id>.md`）；实体不存在返回 null
  Future<String?> resolveNotePath(String noteId) async {
    return _canonicalNotePath('/notes/$noteId.md');
  }

  /// 解析待办实体的规范虚拟路径（`/todos/<分类名>/<id>.md`）；实体不存在返回 null
  Future<String?> resolveTodoPath(String todoId) async {
    return _canonicalTodoPath('/todos/$todoId.md');
  }

  /// 解析时间线记录所属天文件的虚拟路径（`/timeline/YYYY-MM-DD.md`）；记录不存在返回 null
  Future<String?> resolveTimelineDayPath(String recordId) async {
    return _resolveTimelineDayPath('/timeline/$recordId.md');
  }

  /// 每日日记的固定虚拟路径
  String journalPathForDate(DateTime date) {
    final m = date.month.toString().padLeft(2, '0');
    final d = date.day.toString().padLeft(2, '0');
    return '/journal/${date.year}-$m-$d.md';
  }

  /// 将 /timeline/ 下的单条记录路径归一化为天文件路径；记录不存在时返回 null（跳过捕获以保证撤回安全）
  Future<String?> _resolveTimelineDayPath(String path) async {
    final subPath = path.substring('/timeline/'.length).replaceAll('.md', '').trim();
    if (RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(subPath)) return path;

    // 支持带日期前缀（/timeline/日期/<id>.md）与纯 id（/timeline/<id>.md）两种形态
    final recordId = subPath.split('/').last.trim();
    if (recordId.isEmpty) return null;
    try {
      final record = await _diaryRepo.getById(recordId);
      if (record == null) return null;
      final m = record.time.month.toString().padLeft(2, '0');
      final d = record.time.day.toString().padLeft(2, '0');
      return '/timeline/${record.time.year}-$m-$d.md';
    } catch (_) {
      return null;
    }
  }

  /// 将待办路径规范化为 `/todos/<分类名>/<id>.md`，作为录制去重与恢复的统一键
  /// （写回时按路径首段分类落回原分类）；实体不存在或路径不合规时返回 null（沿用原路径）
  Future<String?> _canonicalTodoPath(String path) async {
    if (!path.endsWith('.md')) return null;
    final segments = path.substring('/todos/'.length).split('/');
    final titleWithExt = segments.length >= 2 ? segments.sublist(1).join('/') : segments[0];
    final rawTitle = titleWithExt
        .replaceAll('.md', '')
        .replaceAll(RegExp(r'^\[[ x]\]\s*'), '')
        .trim();
    if (rawTitle.isEmpty) return null;
    try {
      final allTodos = await _todoRepo.getAll();
      final matched = allTodos.where((t) => t.id == rawTitle).firstOrNull ??
          allTodos.where((t) => t.title.trim() == rawTitle).firstOrNull;
      if (matched == null) return null;
      String folderName = '今日';
      final folders = await _folderRepo.getByType('todo');
      folderName = folders
              .where((f) => f.id == matched.folderId)
              .firstOrNull
              ?.name ??
          folderName;
      return '/todos/$folderName/${matched.id}.md';
    } catch (_) {
      return null;
    }
  }

  /// 将笔记路径规范化为 `/notes/<id>.md`（单段路径写回时 folderId 为空会保留原分类），
  /// 作为录制去重与恢复的统一键；实体不存在或路径不合规时返回 null（沿用原路径）
  Future<String?> _canonicalNotePath(String path) async {
    if (!path.endsWith('.md')) return null;
    final rawTitle = path
        .substring('/notes/'.length)
        .split('/')
        .last
        .replaceAll('.md', '')
        .trim();
    if (rawTitle.isEmpty) return null;
    try {
      final allNotes = await _noteRepo.getAll();
      final matched = allNotes.where((n) => n.id == rawTitle).firstOrNull ??
          allNotes.where((n) => n.title.trim() == rawTitle).firstOrNull;
      if (matched == null) return null;
      return '/notes/${matched.id}.md';
    } catch (_) {
      return null;
    }
  }

  static const String agentsDoc = '''# QNote Agent Operating System (AGENTS.md)

欢迎来到 QNote 虚拟工作区。你是智能管家与个人系统助手【小Q】。
在你的运行环境中，QNote 的所有数据统一抽象在根目录 `/` 下的虚拟文件系统中。

## 1. 虚拟文件系统结构
- `/AGENTS.md`: 本工作区指南与系统说明（只读）。
- `/skills/`: 专业技能手册库（查阅对应领域的规范与操作手册）。
- `/memory/`: 小Q长期记忆（`user.md` 用户画像与习惯、`agent.md` 小Q手记；每次对话自动载入上下文，支持查看与增改）。
- `/todos/`: 待办事项库（目录名对应分类，如 `/todos/今日/`、`/todos/长期/`、`/todos/工作/`）。
- `/notes/`: 笔记与知识库（目录名对应笔记本，如 `/notes/技术架构/`。除 Markdown 外还支持写入 `.html` 网页、`.svg` 矢量图、`.json` 数据文件及常见代码文件，App 内会按后缀自动渲染预览；生成展示型内容（卡片、海报、可视化页面）时优先使用带内联样式的单文件 HTML）。
- `/timeline/`: 时间线流水日志（按日期归档，如 `/timeline/2026-09-11.md`，支持单点打卡与时间段打卡）。
- `/journal/`: 每日深度长篇日记与复盘（如 `/journal/2026-09-11.md`）。
- `/folders/`: 分类与笔记本层级管理（`todos.json` 待办分类、`notes.json` 笔记本目录，支持增删改查与重命名）。
- `/stats/`: 数据洞察与生活评分（`summary.json` 综合统计与完成率、`daily_scores.json` 每日AI生活评分与建议）。
- `/chats/`: 对话会话管理（`sessions.json` 历史会话查看、标题重命名与软删除）。
- `/settings/`: 系统偏好与个性化配置（包含 `appearance.json`、`ai.json`、`shortcuts.json`、`fixed_events.json`、`profile.json`、`weight.json`、`color_marks.json`、`webdav.json`）。

## 2. 核心行为准则
1. **像工程师一样自主探索**：优先使用 `list_dir` 查看目录结构，使用 `read_file` 查阅详情，使用 `write_file` 或 `edit_file` 执行变更。
2. **严禁凭空口头承诺**：必须通过实际的文件系统工具调用执行成功后，再向用户汇报结果！
3. **查阅 Skill 手册**：在处理待办规划、笔记重排、时间打卡、系统与AI配置等专业任务时，通过 `read_file(path: "/skills/<skill-name>.md")` 或 `skill(name: "...")` 查阅标准作业程序。
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
        'memory/',
        'todos/',
        'notes/',
        'timeline/',
        'journal/',
        'folders/',
        'stats/',
        'chats/',
        'settings/',
      ];
    }

    if (path == '/skills' || path == '/skills/') {
      return _skillRegistry.listSkills().map((s) => '${s['name']}.md').toList();
    }

    if (path == '/memory' || path == '/memory/') {
      return ['user.md', 'agent.md'];
    }

    if (path == '/folders' || path == '/folders/') {
      return ['todos.json', 'notes.json'];
    }

    if (path == '/stats' || path == '/stats/') {
      return ['summary.json', 'daily_scores.json'];
    }

    if (path == '/chats' || path == '/chats/') {
      return ['sessions.json'];
    }

    if (path == '/settings' || path == '/settings/') {
      return [
        'appearance.json',
        'ai.json',
        'shortcuts.json',
        'fixed_events.json',
        'profile.json',
        'weight.json',
        'color_marks.json',
        'webdav.json',
      ];
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
      final dateSet = <String>{};
      for (int i = 0; i < 7; i++) {
        final d = now.subtract(Duration(days: i));
        final dateStr = '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
        dateSet.add(dateStr);
      }
      try {
        final active = await _diaryRepo.getActiveDates(limit: 30);
        dateSet.addAll(active);
      } catch (_) {}

      final sortedList = dateSet.toList()..sort((a, b) => b.compareTo(a));
      return sortedList.map((d) => '$d.md').toList();
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
    } else if (path.startsWith('/memory/')) {
      fullContent = await _readMemoryFile(path);
    } else if (path.startsWith('/folders/')) {
      fullContent = await _readFoldersFile(path);
    } else if (path.startsWith('/stats/')) {
      fullContent = await _readStatsFile(path);
    } else if (path.startsWith('/chats/')) {
      fullContent = await _readChatsFile(path);
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
      final line = slicedLines[i];
      // 空行不加行号前缀，避免尾部空行经 trimRight 后残留孤立行号
      buffer.writeln(line.isEmpty ? '' : '${start + i + 1}\t$line');
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
    if (matched.repeatRule.isNotEmpty && matched.repeatRule != 'none') {
      buffer.writeln('repeat_rule: "${matched.repeatRule}"');
    }
    if (matched.tags.isNotEmpty) {
      buffer.writeln('tags: "${matched.tags}"');
    }
    if (matched.dueDate != null) {
      buffer.writeln('due_date: "${matched.dueDate!.toIso8601String()}"');
    }
    if (matched.reminderTime != null) {
      buffer.writeln('reminder_time: "${matched.reminderTime}"');
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
      final startStr = '${r.time.hour.toString().padLeft(2, '0')}:${r.time.minute.toString().padLeft(2, '0')}';
      String timeHeader = startStr;
      if (r.endTime != null) {
        final endStr = '${r.endTime!.hour.toString().padLeft(2, '0')}:${r.endTime!.minute.toString().padLeft(2, '0')}';
        timeHeader = '$startStr - $endStr';
      }

      buffer.writeln('## [$timeHeader] ${r.title} <!-- id: ${r.id} -->');
      buffer.writeln('- 分类: ${r.displayTag}');
      buffer.writeln('- 心情: ${r.mood}');
      if (r.weather.isNotEmpty) {
        buffer.writeln('- 天气: ${r.weather}');
      }
      if (r.photos.isNotEmpty) {
        // 仅路径文本模型无法感知画面，附提示引导其调用 view_image 工具加载图片
        buffer.writeln('- 图片: ${r.photos.join(', ')}（可调用 view_image 工具查看图片内容）');
      }
      for (final entry in r.tagEntries) {
        for (final entryField in entry.fields.entries) {
          buffer.writeln('- ${entryField.key}: ${entryField.value}');
        }
      }
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

  /// 读取小Q长期记忆文档；空记忆返回占位文案（存在性由 _buildUndoEntry 按真实存储另行判定）
  Future<String> _readMemoryFile(String path) async {
    final category = AgentMemoryCategory.fromPath(path);
    if (category == null) {
      throw Exception('未知的记忆文件: $path（仅支持 /memory/user.md 与 /memory/agent.md）');
    }
    final doc = await _configRepo.getAgentMemory(category);
    if (doc.content.trim().isEmpty) {
      final title = AgentMemoryCategory.displayName(category);
      return '# $title\n\n> 暂无记忆条目。可以通过 write_file / edit_file 写入，一条一行、以 "- " 开头。';
    }
    return doc.content;
  }

  Future<String> _readSettingsFile(String path) async {
    final name = path.substring('/settings/'.length).trim();
    if (name == 'appearance.json') {
      final prefs = await SharedPreferences.getInstance();
      final themeIndex = prefs.getInt('theme_mode') ?? 0;
      final themeMode = ThemeMode.values[themeIndex.clamp(0, ThemeMode.values.length - 1)];
      final accentVal = prefs.getInt('accent_color') ?? 0xFF005BCB;
      final colorHex = _colorToHex(Color(accentVal));
      final data = {
        'themeMode': _themeModeToString(themeMode),
        'accentColor': colorHex,
        'description': 'themeMode 可选: "system" | "light" | "dark"；accentColor 为 16 进制颜色（如 #005BCB 经典蓝、#C5E803 荧光黄绿、#E91E8C 玫瑰粉红、#00E676 春天亮绿）',
      };
      return const JsonEncoder.withIndent('  ').convert(data);
    } else if (name == 'ai.json') {
      final roles = await _configRepo.getAiRoles() ?? const AiRoles();
      final temps = await _configRepo.getAiTemperatures() ?? const AiTemperatures();
      final customConfigs = await _configRepo.getAllAiConfigs();
      final freeModels = await FreeModelService.instance.getCachedModels();
      final data = {
        'roles': {
          'assistant': {
            'useFreeModel': roles.assistantUseFreeModel,
            'freeModelId': roles.assistantFreeModelId ?? 'gemini-3.5-flash-lite',
            'customModelId': roles.assistant,
          },
          'timelineOptimization': {
            'useFreeModel': roles.timelineOptimizationUseFreeModel,
            'freeModelId': roles.timelineOptimizationFreeModelId ?? 'gemini-3.5-flash-lite',
            'customModelId': roles.timelineOptimization,
          },
        },
        'temperatures': {
          'assistant': {
            'temperature': temps.assistant.temperature,
            'maxTokens': temps.assistant.maxTokens,
          },
          'timelineOptimization': {
            'temperature': temps.timelineOptimization.temperature,
            'maxTokens': temps.timelineOptimization.maxTokens,
            'extractImages': temps.timelineOptimization.extractImages,
          },
        },
        'customModels': customConfigs.map((c) => {
          'id': c.id,
          'name': c.name,
          'provider': c.provider,
          'baseUrl': c.baseUrl,
          'modelName': c.modelName,
          'isDefault': c.isDefault,
        }).toList(),
        'availableFreeModels': freeModels.map((m) => {
          'id': m.id,
          'displayName': m.displayName,
          'provider': m.provider,
          'modelName': m.modelName,
        }).toList(),
      };
      return const JsonEncoder.withIndent('  ').convert(data);
    } else if (name == 'shortcuts.json') {
      final shortcuts = await _configRepo.getAllShortcutConfigs();
      return const JsonEncoder.withIndent('  ').convert(shortcuts.map((s) => s.toMap()).toList());
    } else if (name == 'fixed_events.json') {
      final templates = await FixedEventRepository.instance.getAll();
      return const JsonEncoder.withIndent('  ').convert(templates.map((t) => t.toMap()).toList());
    } else if (name == 'weight.json') {
      final profile = await _configRepo.getUserProfile();
      final history = profile?.weightHistory ?? [];
      final sortedHistory = List<WeightRecord>.from(history)
        ..sort((a, b) => b.time.compareTo(a.time));
      double? latestWeight;
      double? bmi;
      if (sortedHistory.isNotEmpty) {
        latestWeight = sortedHistory.first.weight;
        if (profile?.height != null && profile!.height! > 0) {
          final h = profile.height! / 100.0;
          bmi = double.parse((latestWeight / (h * h)).toStringAsFixed(1));
        }
      }
      final data = {
        'latestWeight': latestWeight,
        'bmi': bmi,
        'height': profile?.height,
        'totalRecords': sortedHistory.length,
        'history': sortedHistory.map((w) => {
          'id': w.id,
          'weight': w.weight,
          'time': w.time.toIso8601String(),
        }).toList(),
      };
      return const JsonEncoder.withIndent('  ').convert(data);
    } else if (name == 'profile.json') {
      final profile = await _configRepo.getUserProfile();
      if (profile == null) {
        return const JsonEncoder.withIndent('  ').convert({'name': 'QNote 用户'});
      }
      final map = profile.toMap();
      try {
        if (map['weight_history'] is String && (map['weight_history'] as String).isNotEmpty) {
          map['weight_history'] = jsonDecode(map['weight_history'] as String);
        }
      } catch (_) {}
      try {
        if (map['custom_fields'] is String && (map['custom_fields'] as String).isNotEmpty) {
          map['custom_fields'] = jsonDecode(map['custom_fields'] as String);
        }
      } catch (_) {}
      return const JsonEncoder.withIndent('  ').convert(map);
    } else if (name == 'color_marks.json') {
      final marks = await _colorMarkRepo.getAll();
      final list = marks.map((m) {
        final hex = m.color.toUpperCase();
        String colorName = '自定义';
        if (hex == '#FFFF3B30' || hex == 'FFFF3B30') colorName = '红色';
        if (hex == '#FF34C759' || hex == 'FF34C759') colorName = '绿色';
        if (hex == '#FF007AFF' || hex == 'FF007AFF') colorName = '蓝色';
        if (hex == '#FFFF9500' || hex == 'FFFF9500') colorName = '橙色';
        if (hex == '#FFAF52DE' || hex == 'FFAF52DE') colorName = '紫色';
        return {
          'id': m.id,
          'date': m.date.toIso8601String().split('T').first,
          'color': hex,
          'name': colorName,
        };
      }).toList();
      return const JsonEncoder.withIndent('  ').convert(list);
    } else if (name == 'webdav.json') {
      final webdav = await _configRepo.getWebdavConfig();
      return const JsonEncoder.withIndent('  ').convert(webdav?.toMap() ?? {'enabled': false});
    }
    throw Exception('未知的配置文件: $path');
  }

  Future<String> _readFoldersFile(String path) async {
    final name = path.substring('/folders/'.length).trim();
    if (name == 'todos.json') {
      final folders = await _folderRepo.getByType('todo');
      return const JsonEncoder.withIndent('  ').convert(
        folders.map((f) => {
          'id': f.id,
          'name': f.name,
          'sortOrder': f.sortOrder,
          'isExpanded': f.isExpanded,
        }).toList(),
      );
    } else if (name == 'notes.json') {
      final folders = await _folderRepo.getByType('note');
      return const JsonEncoder.withIndent('  ').convert(
        folders.map((f) => {
          'id': f.id,
          'name': f.name,
          'parentId': f.parentId,
          'sortOrder': f.sortOrder,
          'isExpanded': f.isExpanded,
        }).toList(),
      );
    }
    throw Exception('未知的分类配置文件: $path');
  }

  Future<String> _readStatsFile(String path) async {
    final name = path.substring('/stats/'.length).trim();
    if (name == 'summary.json') {
      // 1. 待办完成统计
      final allTodos = await _todoRepo.getAll();
      final totalTodos = allTodos.length;
      final completedTodos = allTodos.where((t) => t.isCompleted).length;
      final pendingTodos = totalTodos - completedTodos;
      final completionRate = totalTodos > 0 ? '${(completedTodos / totalTodos * 100).toStringAsFixed(1)}%' : '0.0%';

      // 2. 近 7 天时间线统计
      final now = DateTime.now();
      final startDate = DateTime(now.year, now.month, now.day).subtract(const Duration(days: 6));
      final recentRecords = await _diaryRepo.getByDateRange(startDate, now);

      final categoryCounts = <String, int>{};
      int totalMood = 0;
      int moodRecordCount = 0;
      for (final r in recentRecords) {
        final cat = r.displayTag.isNotEmpty ? r.displayTag : '日常';
        categoryCounts[cat] = (categoryCounts[cat] ?? 0) + 1;
        if (r.mood != null && r.mood! > 0) {
          totalMood += r.mood!;
          moodRecordCount++;
        }
      }

      final avgMood = moodRecordCount > 0 ? (totalMood / moodRecordCount).toStringAsFixed(1) : '3.0';

      final data = {
        'timeRange': '${startDate.toIso8601String().substring(0, 10)} ~ ${now.toIso8601String().substring(0, 10)}',
        'todos': {
          'total': totalTodos,
          'completed': completedTodos,
          'pending': pendingTodos,
          'completionRate': completionRate,
        },
        'timeline': {
          'recent7DaysRecordCount': recentRecords.length,
          'averageMood': avgMood,
          'categoryDistribution': categoryCounts,
        },
      };
      return const JsonEncoder.withIndent('  ').convert(data);
    } else if (name == 'daily_scores.json') {
      final now = DateTime.now();
      final startDate = DateTime(now.year, now.month, now.day).subtract(const Duration(days: 14));
      final scores = await _dailyScoreRepo.getByDateRange(startDate, now);
      final list = scores.map((s) => {
        'date': s.date.toIso8601String().substring(0, 10),
        'totalScore': s.totalScore,
        'dimensionScores': s.dimensionScores,
        'summary': s.summary,
        'suggestions': s.suggestions,
        'recordCount': s.recordCount,
      }).toList();
      return const JsonEncoder.withIndent('  ').convert(list);
    }
    throw Exception('未知的统计数据路径: $path');
  }

  Future<String> _readChatsFile(String path) async {
    final name = path.substring('/chats/'.length).trim();
    if (name == 'sessions.json') {
      final sessions = await _configRepo.getAllChatSessions();
      final list = sessions.map((s) => {
        'id': s.id,
        'title': s.title,
        'messageCount': s.messages.length,
        'createdAt': s.createdAt.toIso8601String(),
        'updatedAt': s.updatedAt.toIso8601String(),
      }).toList();
      return const JsonEncoder.withIndent('  ').convert(list);
    }
    throw Exception('未知的会话管理文件: $path');
  }

  // ==========================================
  // 3. writeFile: 写入/新建虚拟文件
  // ==========================================
  Future<Map<String, dynamic>> writeFile(String rawPath, String content) async {
    final path = normalizePath(rawPath);
    // 撤回录制：捕获本轮首次修改前的旧状态（editFile 内部最终也走 writeFile，靠同路径去重）
    await _captureUndoState(path);

    if (path.startsWith('/todos/')) {
      return await _writeTodoFile(path, content);
    } else if (path.startsWith('/notes/')) {
      return await _writeNoteFile(path, content);
    } else if (path.startsWith('/timeline/')) {
      return await _writeTimelineFile(path, content);
    } else if (path.startsWith('/journal/')) {
      return await _writeJournalFile(path, content);
    } else if (path.startsWith('/memory/')) {
      return await _writeMemoryFile(path, content);
    } else if (path.startsWith('/folders/')) {
      return await _writeFoldersFile(path, content);
    } else if (path.startsWith('/chats/')) {
      return await _writeChatsFile(path, content);
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

    // 重复规则
    final rawRepeat = (meta['repeat_rule'] ?? meta['repeat'] ?? '').toString().trim().toLowerCase();
    String repeatRule = 'none';
    if (rawRepeat == 'daily' || rawRepeat == '每天' || rawRepeat == '每日') {
      repeatRule = 'daily';
    } else if (rawRepeat == 'workday' || rawRepeat == '工作日') {
      repeatRule = 'workday';
    } else if (rawRepeat == 'weekly' || rawRepeat == '每周') {
      repeatRule = 'weekly';
    } else if (rawRepeat == 'monthly' || rawRepeat == '每月') {
      repeatRule = 'monthly';
    } else if (rawRepeat == 'yearly' || rawRepeat == '每年') {
      repeatRule = 'yearly';
    } else if (['daily', 'workday', 'weekly', 'monthly', 'yearly', 'none'].contains(rawRepeat)) {
      repeatRule = rawRepeat;
    }

    // 标签
    String tags = '';
    if (meta['tags'] != null) {
      if (meta['tags'] is List) {
        tags = (meta['tags'] as List).map((e) => e.toString().trim()).join(',');
      } else {
        tags = meta['tags'].toString().replaceAll('[', '').replaceAll(']', '').replaceAll('"', '').trim();
      }
    }

    DateTime? dueDate;
    if (meta['due_date'] != null) {
      try {
        dueDate = DateTime.parse(meta['due_date'].toString().replaceAll('"', ''));
      } catch (_) {}
    }

    // 提醒时间：归一化为 MM-DD HH:mm 存储，这是一切通知的唯一触发源
    // （due_date 仅作记录，不会触发通知、应用内也不展示）
    final String? reminderTime = ReminderUtils.normalize(
      meta['reminder_time'] ?? meta['remind_at'] ?? meta['reminder'],
    );

    // 2. 解析或自动创建分类
    final folderId = await _resolveTodoFolder(folderName, isLongTerm: isLongTerm);

    // 3. 判断是更新还是创建
    final allTodos = await _todoRepo.getAll();
    final existingId = meta['id']?.toString().replaceAll('"', '');
    Todo? existing;
    if (existingId != null && existingId.isNotEmpty) {
      existing = allTodos.where((t) => t.id == existingId).firstOrNull;
      // 撤回恢复场景：id 命中已软删除的记录时复活，否则被删待办写回后仍然不可见
      if (existing == null) {
        final allWithDeleted = await _todoRepo.getAll(includeDeleted: true);
        existing = allWithDeleted.where((t) => t.id == existingId && t.isDeleted).firstOrNull;
      }
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
        reminderTime: reminderTime ?? existing.reminderTime,
        repeatRule: repeatRule != 'none' ? repeatRule : existing.repeatRule,
        tags: tags.isNotEmpty ? tags : existing.tags,
        folderId: folderId,
        isLongTerm: isLongTerm,
        isDeleted: false,
        updatedAt: now,
      );
      await _todoRepo.update(updated);
      await NotificationService.instance.scheduleTodoReminder(updated);
      WorkspaceEventBus.instance.emit(path, WorkspaceChangeType.updated, updated);
      return {
        'status': 'updated',
        'path': path,
        'id': updated.id,
        'title': updated.title,
        'folder': folderName,
        'folder_id': folderId,
        'is_completed': updated.isCompleted,
        'due_date': _formatDueForDisplay(updated.dueDate),
        'reminder_time': updated.reminderTime,
        'repeat_rule': updated.repeatRule,
        'tags': updated.tags,
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
        reminderTime: reminderTime,
        repeatRule: repeatRule,
        tags: tags,
        sortOrder: now.millisecondsSinceEpoch,
        createdAt: now,
        updatedAt: now,
      );
      await _todoRepo.insert(newTodo);
      await NotificationService.instance.scheduleTodoReminder(newTodo);
      WorkspaceEventBus.instance.emit(path, WorkspaceChangeType.created, newTodo);
      return {
        'status': 'created',
        'path': path,
        'id': newTodo.id,
        'title': newTodo.title,
        'folder': folderName,
        'folder_id': folderId,
        'is_completed': newTodo.isCompleted,
        'due_date': _formatDueForDisplay(newTodo.dueDate),
        'reminder_time': newTodo.reminderTime,
        'repeat_rule': newTodo.repeatRule,
        'tags': newTodo.tags,
      };
    }
  }

  /// 供工具返回结果展示的截止时间文本（应用内提醒实际依赖 reminder_time）
  String? _formatDueForDisplay(DateTime? due) {
    if (due == null) return null;
    final y = due.year.toString().padLeft(4, '0');
    final m = due.month.toString().padLeft(2, '0');
    final d = due.day.toString().padLeft(2, '0');
    final hh = due.hour.toString().padLeft(2, '0');
    final mi = due.minute.toString().padLeft(2, '0');
    return '$y-$m-$d $hh:$mi';
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
    if (existingId != null && existingId.isNotEmpty) {
      existing = allNotes.where((n) => n.id == existingId).firstOrNull;
      // 撤回恢复场景：id 命中已软删除的记录时复活，否则被删笔记写回后仍然不可见
      if (existing == null) {
        final allWithDeleted = await _noteRepo.getAll(includeDeleted: true);
        existing = allWithDeleted.where((n) => n.id == existingId && n.isDeleted).firstOrNull;
      }
    }
    existing ??= allNotes.where((n) => n.title.trim() == title && n.folderId == folderId).firstOrNull;

    final tagsStr = meta['tags'] is List
        ? (meta['tags'] as List).join(', ')
        : (meta['tags']?.toString() ?? '');

    // 从 Markdown 正文提取图片链接回填 images 索引列：
    // WebDAV 同步只认 notes.images 列收集活动图片，不回填会导致小Q插入的
    // 生成图片/外链图片被视为孤儿文件而在同步时被清理
    final extractedImages = _extractImagesFromMarkdown(noteContent);

    final now = DateTime.now();
    if (existing != null) {
      final updated = existing.copyWith(
        title: title.isNotEmpty ? title : existing.title,
        content: noteContent,
        folderId: folderId ?? existing.folderId,
        isPinned: meta['pinned'] == true,
        tags: tagsStr.isNotEmpty ? tagsStr : existing.tags,
        images: extractedImages.isNotEmpty ? extractedImages : existing.images,
        isDeleted: false,
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
        images: extractedImages,
        createdAt: now,
        updatedAt: now,
      );
      await _noteRepo.insert(newNote);
      WorkspaceEventBus.instance.emit(path, WorkspaceChangeType.created, newNote);
      return {'status': 'created', 'path': path, 'id': newNote.id, 'title': newNote.title};
    }
  }

  /// 从 Markdown 正文提取图片链接路径（`![...](路径)`），保持出现顺序并去重
  ///
  /// 与笔记编辑器的图片段识别规则一致：仅匹配独立成行的图片语法；
  /// data URI（Web 端内嵌图）体积过大且无需同步，跳过不入索引。
  static List<String> _extractImagesFromMarkdown(String content) {
    final pattern = RegExp(r'^!\[.*?\]\((.*?)\)\s*$', multiLine: true);
    final paths = <String>[];
    for (final match in pattern.allMatches(content)) {
      final path = match.group(1)?.trim() ?? '';
      if (path.isEmpty || path.startsWith('data:')) continue;
      if (!paths.contains(path)) paths.add(path);
    }
    return paths;
  }

  Future<Map<String, dynamic>> _writeTimelineFile(String path, String content) async {
    final dateStr = path.substring('/timeline/'.length).replaceAll('.md', '').trim();
    DateTime baseDate;
    try {
      baseDate = DateTime.parse(dateStr);
    } catch (_) {
      baseDate = DateTime.now();
    }

    // 获取当天数据库中现存的所有活跃记录，用于差量比对（Diff Deletion）
    final existingRecords = await _diaryRepo.getByDate(baseDate);

    // 解析 markdown 块。支持时间点 ## [HH:MM] 与时间段 ## [HH:MM - HH:MM]
    final blockRegex = RegExp(
      r'##\s*\[(\d{1,2}:\d{2})(?:\s*[-~至到]\s*(\d{1,2}:\d{2}))?\]\s*([^\n]+)(?:<!--\s*id:\s*([^\s>]+)\s*-->)?([\s\S]*?)(?=##\s*\[|(?![\s\S]))',
    );
    final matches = blockRegex.allMatches(content);

    // 记录本次写回中保留或新建的记录 ID
    final retainedIds = <String>{};
    int count = 0;
    int updatedCount = 0;
    int createdCount = 0;

    for (final m in matches) {
      final startTimeStr = m.group(1)!.trim();
      final endTimeStr = m.group(2)?.trim();
      var title = m.group(3) ?? '';
      final inlineId = RegExp(r'<!--\s*id:\s*([^\s>]+)\s*-->').firstMatch(title);
      final recordId = inlineId?.group(1)?.trim() ?? m.group(4)?.trim();
      title = title.replaceAll(RegExp(r'<!--.*?-->'), '').trim();
      final body = m.group(5)?.trim() ?? '';

      final timeParts = startTimeStr.split(':');
      final recordTime = DateTime(
        baseDate.year,
        baseDate.month,
        baseDate.day,
        int.parse(timeParts[0]),
        int.parse(timeParts[1]),
      );

      DateTime? endDateTime;
      if (endTimeStr != null && endTimeStr.isNotEmpty) {
        final endParts = endTimeStr.split(':');
        endDateTime = DateTime(
          baseDate.year,
          baseDate.month,
          baseDate.day,
          int.parse(endParts[0]),
          int.parse(endParts[1]),
        );
      }

      String category = '日常';
      int? mood;
      String detail = '';
      String weather = '';
      final photos = <String>[];
      final customFields = <String, dynamic>{};

      for (final line in body.split('\n')) {
        final l = line.trim().replaceAll('：', ':');
        if (l.startsWith('- 分类:') || l.startsWith('- category:')) {
          category = _fieldValue(l);
        } else if (l.startsWith('- 心情:') || l.startsWith('- mood:')) {
          mood = int.tryParse(_fieldValue(l));
        } else if (l.startsWith('- 天气:') || l.startsWith('- weather:')) {
          weather = _fieldValue(l);
        } else if (l.startsWith('- 标记颜色:') || l.startsWith('- 颜色标记:') || l.startsWith('- color_mark:')) {
          final colorVal = _fieldValue(l);
          if (colorVal.isNotEmpty) {
            String hexColor = '#FFFF3B30';
            if (colorVal == 'green' || colorVal == '绿色') {
              hexColor = '#FF34C759';
            } else if (colorVal == 'blue' || colorVal == '蓝色') {
              hexColor = '#FF007AFF';
            } else if (colorVal == 'orange' || colorVal == '橙色') {
              hexColor = '#FFFF9500';
            } else if (colorVal == 'purple' || colorVal == '紫色') {
              hexColor = '#FFAF52DE';
            } else if (colorVal == 'red' || colorVal == '红色') {
              hexColor = '#FFFF3B30';
            } else {
              final c = _parseColor(colorVal);
              if (c != null) {
                hexColor = '#${c.toARGB32().toRadixString(16).padLeft(8, '0').toUpperCase()}';
              }
            }
            _colorMarkRepo.insert(DateColorMark(
              id: const Uuid().v4(),
              date: baseDate,
              color: hexColor,
            ));
            WorkspaceEventBus.instance.emit(
              '/settings/color_marks.json',
              WorkspaceChangeType.updated,
              {'date': dateStr, 'color': hexColor},
            );
          }
        } else if (l.startsWith('- 图片:') || l.startsWith('- photo:') || l.startsWith('- photos:')) {
          final pStr = _fieldValue(l);
          for (final p in pStr.split(',')) {
            // 读取时行尾附加了 view_image 提示标注，写回解析时剥离，避免混入图片路径
            final item = p.trim().replaceAll(RegExp('（可调用[^）]*）'), '').trim();
            if (item.isNotEmpty) photos.add(item);
          }
        } else if (l.startsWith('- 详情:') ||
            l.startsWith('- detail:') ||
            l.startsWith('- 内容:') ||
            l.startsWith('- content:')) {
          detail = _fieldValue(l);
        } else if (l.startsWith('- ') && l.contains(':')) {
          // 结构化指标识别（如「- 饮水: 500ml」、「- 消费金额: 35」）
          final key = l.substring(2, l.indexOf(':')).trim();
          final val = _fieldValue(l);
          if (key.isNotEmpty && val.isNotEmpty) {
            customFields[key] = val;
          }
        } else if (l.isNotEmpty) {
          detail += (detail.isEmpty ? '' : '\n') + l;
        }
      }

      final tagEntries = <TagEntry>[];
      if (customFields.isNotEmpty) {
        tagEntries.add(
          TagEntry(
            id: const Uuid().v4(),
            name: category,
            fields: customFields,
            time: '${recordTime.hour.toString().padLeft(2, '0')}:${recordTime.minute.toString().padLeft(2, '0')}',
          ),
        );
      }

      final now = DateTime.now();
      DiaryRecord? existing;
      if (recordId != null && recordId.isNotEmpty) {
        existing = await _diaryRepo.getById(recordId);
      }
      existing ??= await _findTimelineRecord(baseDate, recordTime, title);

      if (existing != null) {
        final updated = existing.copyWith(
          title: title.isNotEmpty ? title : existing.title,
          content: detail,
          displayTag: category,
          tags: [category],
          time: recordTime,
          startTime: recordTime,
          endTime: endDateTime ?? existing.endTime,
          mood: mood ?? existing.mood,
          weather: weather.isNotEmpty ? weather : existing.weather,
          photos: photos.isNotEmpty ? photos : existing.photos,
          tagEntries: tagEntries.isNotEmpty ? tagEntries : existing.tagEntries,
          // 撤回恢复场景：id 命中已软删除的记录（getById 不过滤软删）时复活，否则写回后仍不可见
          isDeleted: false,
          updatedAt: now,
        );
        await _diaryRepo.update(updated);
        retainedIds.add(existing.id);
        count++;
        updatedCount++;
        continue;
      }

      final newRecord = DiaryRecord(
        id: const Uuid().v4(),
        title: title,
        content: detail,
        displayTag: category,
        tags: [category],
        time: recordTime,
        startTime: recordTime,
        endTime: endDateTime,
        mood: mood ?? 3,
        weather: weather,
        photos: photos,
        tagEntries: tagEntries,
        createdAt: now,
        updatedAt: now,
      );
      await _diaryRepo.insert(newRecord);
      retainedIds.add(newRecord.id);
      count++;
      createdCount++;
    }

    // 差量比对：软删除本次写回中已被移除的原有记录
    int deletedCount = 0;
    if (count > 0) {
      for (final oldRecord in existingRecords) {
        if (!retainedIds.contains(oldRecord.id)) {
          await _diaryRepo.softDelete(oldRecord.id);
          WorkspaceEventBus.instance.emit(path, WorkspaceChangeType.deleted, oldRecord);
          deletedCount++;
        }
      }
    } else {
      // count == 0: 检查是否属于显式清空意图（剥除文件标题、提示引述行和空行）
      final remainingLines = content.split('\n').where((line) {
        final t = line.trim();
        if (t.isEmpty) return false;
        if (t.startsWith('#')) return false;
        if (t.startsWith('>')) return false;
        return true;
      }).toList();

      if (remainingLines.isEmpty) {
        // 显式清空：若当天有记录，则全部软删除
        for (final oldRecord in existingRecords) {
          await _diaryRepo.softDelete(oldRecord.id);
          WorkspaceEventBus.instance.emit(path, WorkspaceChangeType.deleted, oldRecord);
          deletedCount++;
        }
        WorkspaceEventBus.instance.emit(path, WorkspaceChangeType.updated, {
          'date': dateStr,
          'count': 0,
          'deleted': deletedCount,
        });
        return {
          'status': 'success',
          'path': path,
          'records_processed': 0,
          'records_deleted': deletedCount,
          'message': '已清空 $dateStr 的全部时间线流水',
        };
      }

      // 若还有其它非格式内容，说明模型误用了纯文本或 Frontmatter 写入，必须拦截避免静默失败
      throw Exception(
        '未在 /timeline/ 内容中识别到任何时间线事件块，本次写入已被拒绝（避免静默失败）。\n'
        '时间线必须使用二级标题「时间块」格式，且严禁使用 YAML Frontmatter：\n\n'
        '## [HH:MM] 事件标题\n'
        '- 分类: 饮食          （可选，默认「日常」）\n'
        '- 心情: 4             （可选，1~5）\n'
        '- 详情: 具体内容      （可选）\n\n'
        '示例：\n'
        '## [12:00] 午餐\n'
        '- 分类: 饮食\n'
        '- 详情: 中午吃了一碗方便面\n',
      );
    }

    WorkspaceEventBus.instance.emit(path, WorkspaceChangeType.updated, {
      'date': dateStr,
      'count': count,
      'created': createdCount,
      'updated': updatedCount,
      'deleted': deletedCount,
    });
    return {
      'status': 'success',
      'path': path,
      'records_processed': count,
      'records_created': createdCount,
      'records_updated': updatedCount,
      'records_deleted': deletedCount,
    };
  }

  /// 按「同一天 + 同一时刻 + 同一标题」查找已有时间线记录，作为 id 注释丢失时的去重兜底
  Future<DiaryRecord?> _findTimelineRecord(DateTime date, DateTime recordTime, String title) async {
    final trimmed = title.trim();
    if (trimmed.isEmpty) return null;
    final records = await _diaryRepo.getByDate(date);
    return records.where((r) {
      return r.time.hour == recordTime.hour &&
          r.time.minute == recordTime.minute &&
          r.title.trim() == trimmed;
    }).firstOrNull;
  }

  /// 取「字段名: 值」中第一个冒号之后的全部内容（值本身可含冒号，不能用 split 取固定下标）
  String _fieldValue(String line) {
    final idx = line.indexOf(':');
    if (idx == -1 || idx == line.length - 1) return '';
    return line.substring(idx + 1).trim();
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

  /// 写入小Q长期记忆文档：校验分类与容量上限，保存并广播事件。
  /// 容量超限直接抛错（对齐 Hermes 有界记忆），引导小Q先整合再写入
  Future<Map<String, dynamic>> _writeMemoryFile(String path, String content) async {
    final category = AgentMemoryCategory.fromPath(path);
    if (category == null) {
      throw Exception('未知的记忆文件: $path（仅支持 /memory/user.md 与 /memory/agent.md）');
    }
    final normalized = content.trim();
    final maxChars = AgentMemoryCategory.maxChars(category);
    if (normalized.length > maxChars) {
      throw Exception(
        '记忆容量已超限（${normalized.length}/$maxChars 字符）。请先 read_file 查阅现有条目，整合或删除过时内容后再写入。',
      );
    }
    final doc = AgentMemoryDocument(category: category, content: normalized);
    await _configRepo.saveAgentMemory(doc);
    WorkspaceEventBus.instance.emit(path, WorkspaceChangeType.updated, doc.toMap());
    return {
      'status': 'updated',
      'path': path,
      'usage': '${doc.usagePercent}%（${normalized.length}/$maxChars 字符）',
    };
  }

  Future<Map<String, dynamic>> _writeSettingsFile(String path, String content) async {
    final name = path.substring('/settings/'.length).trim();
    dynamic decoded;
    try {
      decoded = jsonDecode(content);
    } catch (e) {
      throw Exception('配置文件必须为合法 JSON 格式: $e');
    }

    if (name == 'appearance.json') {
      if (decoded is! Map<String, dynamic>) {
        throw Exception('appearance.json 必须是 JSON 对象');
      }
      final prefs = await SharedPreferences.getInstance();
      if (decoded.containsKey('themeMode')) {
        final mode = _parseThemeMode(decoded['themeMode']);
        await prefs.setInt('theme_mode', mode.index);
      }
      if (decoded.containsKey('accentColor')) {
        final color = _parseColor(decoded['accentColor']);
        if (color != null) {
          await prefs.setInt('accent_color', color.toARGB32());
        }
      }
      final currentThemeIndex = prefs.getInt('theme_mode') ?? 0;
      final currentColorVal = prefs.getInt('accent_color') ?? 0xFF005BCB;
      final updatedData = {
        'themeMode': _themeModeToString(ThemeMode.values[currentThemeIndex]),
        'accentColor': _colorToHex(Color(currentColorVal)),
      };
      WorkspaceEventBus.instance.emit(path, WorkspaceChangeType.updated, updatedData);
      return {'status': 'updated', 'path': path, 'data': updatedData};
    }

    if (name == 'ai.json') {
      if (decoded is! Map<String, dynamic>) {
        throw Exception('ai.json 必须是 JSON 对象');
      }
      // 1. 更新 roles
      if (decoded.containsKey('roles') && decoded['roles'] is Map<String, dynamic>) {
        final rolesMap = decoded['roles'] as Map<String, dynamic>;
        var currentRoles = await _configRepo.getAiRoles() ?? const AiRoles();
        if (rolesMap.containsKey('assistant') && rolesMap['assistant'] is Map<String, dynamic>) {
          final ast = rolesMap['assistant'] as Map<String, dynamic>;
          currentRoles = currentRoles.copyWith(
            assistantUseFreeModel: ast['useFreeModel'] as bool? ?? currentRoles.assistantUseFreeModel,
            assistantFreeModelId: ast['freeModelId'] as String? ?? currentRoles.assistantFreeModelId,
            assistant: ast.containsKey('customModelId') ? ast['customModelId'] as String? : currentRoles.assistant,
          );
        }
        if (rolesMap.containsKey('timelineOptimization') && rolesMap['timelineOptimization'] is Map<String, dynamic>) {
          final tlo = rolesMap['timelineOptimization'] as Map<String, dynamic>;
          currentRoles = currentRoles.copyWith(
            timelineOptimizationUseFreeModel: tlo['useFreeModel'] as bool? ?? currentRoles.timelineOptimizationUseFreeModel,
            timelineOptimizationFreeModelId: tlo['freeModelId'] as String? ?? currentRoles.timelineOptimizationFreeModelId,
            timelineOptimization: tlo.containsKey('customModelId') ? tlo['customModelId'] as String? : currentRoles.timelineOptimization,
          );
        }
        await _configRepo.saveAiRoles(currentRoles);
      }

      // 2. 更新 temperatures
      if (decoded.containsKey('temperatures') && decoded['temperatures'] is Map<String, dynamic>) {
        final tempsMap = decoded['temperatures'] as Map<String, dynamic>;
        var currentTemps = await _configRepo.getAiTemperatures() ?? const AiTemperatures();
        if (tempsMap.containsKey('assistant') && tempsMap['assistant'] is Map<String, dynamic>) {
          final ast = tempsMap['assistant'] as Map<String, dynamic>;
          currentTemps = currentTemps.copyWith(
            assistant: currentTemps.assistant.copyWith(
              temperature: (ast['temperature'] as num?)?.toDouble() ?? currentTemps.assistant.temperature,
              maxTokens: (ast['maxTokens'] as num?)?.toInt() ?? currentTemps.assistant.maxTokens,
            ),
          );
        }
        if (tempsMap.containsKey('timelineOptimization') && tempsMap['timelineOptimization'] is Map<String, dynamic>) {
          final tlo = tempsMap['timelineOptimization'] as Map<String, dynamic>;
          currentTemps = currentTemps.copyWith(
            timelineOptimization: currentTemps.timelineOptimization.copyWith(
              temperature: (tlo['temperature'] as num?)?.toDouble() ?? currentTemps.timelineOptimization.temperature,
              maxTokens: (tlo['maxTokens'] as num?)?.toInt() ?? currentTemps.timelineOptimization.maxTokens,
              extractImages: (tlo['extractImages'] as bool?) ?? currentTemps.timelineOptimization.extractImages,
            ),
          );
        }
        await _configRepo.saveAiTemperatures(currentTemps);
      }

      WorkspaceEventBus.instance.emit(path, WorkspaceChangeType.updated, decoded);
      return {'status': 'updated', 'path': path};
    }

    if (name == 'shortcuts.json') {
      List<dynamic> list;
      if (decoded is List) {
        list = decoded;
      } else if (decoded is Map<String, dynamic> && decoded['shortcuts'] is List) {
        list = decoded['shortcuts'] as List;
      } else if (decoded is Map<String, dynamic>) {
        list = [decoded];
      } else {
        throw Exception('shortcuts.json 必须是快捷按钮数组或包含 shortcuts 字段的对象');
      }

      final current = await _configRepo.getAllShortcutConfigs();
      final currentMap = {for (final s in current) s.id: s};

      for (int i = 0; i < list.length; i++) {
        final item = list[i];
        if (item is! Map<String, dynamic>) continue;
        final map = Map<String, dynamic>.from(item);
        final id = map['id']?.toString() ?? const Uuid().v4();
        map['id'] = id;

        final now = DateTime.now();
        final config = ShortcutConfig(
          id: id,
          name: (map['name'] ?? map['label'] ?? '未命名快捷键').toString(),
          hasPopup: map['has_popup'] == 1 || map['hasPopup'] == true,
          sortOrder: (map['sort_order'] ?? map['sortOrder'] as num?)?.toInt() ?? i,
          isVisible: map['is_visible'] != 0 && map['isVisible'] != false,
          createdAt: currentMap[id]?.createdAt ?? now,
          updatedAt: now,
        );

        if (currentMap.containsKey(id)) {
          await _configRepo.updateShortcutConfig(config);
        } else {
          await _configRepo.insertShortcutConfig(config);
        }
      }

      WorkspaceEventBus.instance.emit(path, WorkspaceChangeType.updated, list);
      return {'status': 'updated', 'path': path, 'count': list.length};
    }

    if (name == 'fixed_events.json') {
      List<dynamic> list;
      if (decoded is List) {
        list = decoded;
      } else if (decoded is Map<String, dynamic> && decoded['events'] is List) {
        list = decoded['events'] as List;
      } else if (decoded is Map<String, dynamic>) {
        list = [decoded];
      } else {
        throw Exception('fixed_events.json 必须是固定事件数组');
      }

      final repo = FixedEventRepository.instance;
      final current = await repo.getAll();
      final currentMap = {for (final e in current) e.id: e};

      for (int i = 0; i < list.length; i++) {
        final item = list[i];
        if (item is! Map<String, dynamic>) continue;
        final map = Map<String, dynamic>.from(item);
        final id = map['id']?.toString() ?? const Uuid().v4();
        map['id'] = id;
        final now = DateTime.now();
        final name = (map['name'] ?? map['title'] ?? '未命名习惯').toString();
        final startTime = (map['start_time'] ?? map['startTime'] ?? '08:00').toString();
        final endTime = (map['end_time'] ?? map['endTime'] ?? '').toString();
        final isTimePoint = map['is_time_point'] == 1 || map['isTimePoint'] == true;
        final content = map['content']?.toString();
        final isEnabled = map['is_enabled'] != 0 && map['isEnabled'] != false;
        final sortOrder = (map['sort_order'] ?? map['sortOrder'] as num?)?.toInt() ?? i;

        final template = FixedEventTemplate(
          id: id,
          name: name,
          startTime: startTime,
          endTime: endTime,
          isTimePoint: isTimePoint,
          content: content,
          sortOrder: sortOrder,
          isEnabled: isEnabled,
          createdAt: currentMap[id]?.createdAt ?? now,
          updatedAt: now,
        );

        if (currentMap.containsKey(id)) {
          await repo.update(template);
        } else {
          await repo.insert(template);
        }
      }

      WorkspaceEventBus.instance.emit(path, WorkspaceChangeType.updated, list);
      return {'status': 'updated', 'path': path, 'count': list.length};
    }

    if (name == 'weight.json') {
      double? newWeight;
      DateTime time = DateTime.now();
      if (decoded is Map<String, dynamic>) {
        newWeight = (decoded['weight'] as num?)?.toDouble();
        if (decoded['time'] != null) {
          try {
            time = DateTime.parse(decoded['time'].toString());
          } catch (_) {}
        }
      } else if (decoded is num) {
        newWeight = decoded.toDouble();
      }
      if (newWeight == null || newWeight <= 0) {
        throw Exception('weight.json 必须包含有效的 weight 数值（例如: {"weight": 68.5}）');
      }
      final profile = await _configRepo.getUserProfile() ?? UserProfile(
        id: const Uuid().v4(),
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
      final record = WeightRecord(
        id: const Uuid().v4(),
        weight: newWeight,
        time: time,
      );
      final updatedProfile = profile.copyWith(
        weightHistory: [...profile.weightHistory, record],
      );
      await _configRepo.saveUserProfile(updatedProfile);
      WorkspaceEventBus.instance.emit('/settings/profile.json', WorkspaceChangeType.updated, updatedProfile);
      WorkspaceEventBus.instance.emit(path, WorkspaceChangeType.updated, record);
      return {
        'status': 'created',
        'path': path,
        'weight': newWeight,
        'time': time.toIso8601String(),
      };
    }

    if (name == 'profile.json') {
      if (decoded is! Map<String, dynamic>) {
        throw Exception('profile.json 必须是 JSON 对象');
      }
      final existing = await _configRepo.getUserProfile();
      final mergedMap = Map<String, dynamic>.from(existing?.toMap() ?? {});
      mergedMap.addAll(decoded);

      // 类型归一化：若模型传入原生 List/Map，转换为 JSON 字符串以防 ClassCastException
      if (mergedMap['weight_history'] != null && mergedMap['weight_history'] is! String) {
        mergedMap['weight_history'] = jsonEncode(mergedMap['weight_history']);
      }
      if (mergedMap['custom_fields'] != null && mergedMap['custom_fields'] is! String) {
        mergedMap['custom_fields'] = jsonEncode(mergedMap['custom_fields']);
      }

      mergedMap['id'] = existing?.id ?? const Uuid().v4();
      mergedMap['updated_at'] = DateTime.now().toIso8601String();
      if (!mergedMap.containsKey('created_at')) {
        mergedMap['created_at'] = DateTime.now().toIso8601String();
      }

      final profile = UserProfile.fromMap(mergedMap);
      await _configRepo.saveUserProfile(profile);
      WorkspaceEventBus.instance.emit(path, WorkspaceChangeType.updated, profile);
      return {'status': 'updated', 'path': path, 'name': profile.name};
    }

    if (name == 'color_marks.json') {
      List<dynamic> list;
      if (decoded is List) {
        list = decoded;
      } else if (decoded is Map<String, dynamic> && decoded['marks'] is List) {
        list = decoded['marks'] as List;
      } else if (decoded is Map<String, dynamic>) {
        list = [decoded];
      } else {
        throw Exception('color_marks.json 必须是标记数组或包含 marks 字段的对象');
      }

      int processed = 0;
      for (final item in list) {
        if (item is! Map<String, dynamic>) continue;
        final dateStr = item['date']?.toString().trim();
        final rawColor = item['color']?.toString().trim().toLowerCase();
        if (dateStr == null || dateStr.isEmpty) continue;

        DateTime date;
        try {
          date = DateTime.parse(dateStr);
        } catch (_) {
          continue;
        }

        if (rawColor == null || rawColor.isEmpty || rawColor == 'none' || rawColor == 'clear' || rawColor == '清除') {
          await _colorMarkRepo.deleteByDate(date);
          processed++;
          continue;
        }

        // 解析颜色
        String hexColor = '#FFFF3B30'; // 默认红色
        if (rawColor == 'red' || rawColor == '红色') {
          hexColor = '#FFFF3B30';
        } else if (rawColor == 'green' || rawColor == '绿色') {
          hexColor = '#FF34C759';
        } else if (rawColor == 'blue' || rawColor == '蓝色') {
          hexColor = '#FF007AFF';
        } else if (rawColor == 'orange' || rawColor == '橙色') {
          hexColor = '#FFFF9500';
        } else if (rawColor == 'purple' || rawColor == '紫色') {
          hexColor = '#FFAF52DE';
        } else {
          final c = _parseColor(rawColor);
          if (c != null) {
            hexColor = '#${c.toARGB32().toRadixString(16).padLeft(8, '0').toUpperCase()}';
          }
        }

        final mark = DateColorMark(
          id: const Uuid().v4(),
          date: date,
          color: hexColor,
        );
        await _colorMarkRepo.insert(mark);
        processed++;
      }

      WorkspaceEventBus.instance.emit('/settings/color_marks.json', WorkspaceChangeType.updated, {'count': processed});
      WorkspaceEventBus.instance.emit('/timeline/', WorkspaceChangeType.updated, {'count': processed});
      return {'status': 'updated', 'path': path, 'count': processed};
    }

    if (name == 'webdav.json') {
      if (decoded is! Map<String, dynamic>) {
        throw Exception('webdav.json 必须是 JSON 对象');
      }
      final existing = await _configRepo.getWebdavConfig();
      final mergedMap = Map<String, dynamic>.from(existing?.toMap() ?? {});
      mergedMap.addAll(decoded);
      if (!mergedMap.containsKey('id')) {
        mergedMap['id'] = existing?.id ?? const Uuid().v4();
      }
      mergedMap['updated_at'] = DateTime.now().toIso8601String();

      final webdav = WebdavConfig.fromMap(mergedMap);
      await _configRepo.upsertWebdavConfig(webdav);
      WorkspaceEventBus.instance.emit(path, WorkspaceChangeType.updated, webdav);
      return {'status': 'updated', 'path': path};
    }

    throw Exception('不支持修改此配置: $path');
  }

  Future<Map<String, dynamic>> _writeFoldersFile(String path, String content) async {
    final name = path.substring('/folders/'.length).trim();
    dynamic decoded;
    try {
      decoded = jsonDecode(content);
    } catch (e) {
      throw Exception('分类配置必须为合法 JSON 格式: $e');
    }

    final type = name == 'todos.json' ? 'todo' : (name == 'notes.json' ? 'note' : null);
    if (type == null) {
      throw Exception('不支持修改的分类配置: $path');
    }

    List<dynamic> list;
    if (decoded is List) {
      list = decoded;
    } else if (decoded is Map<String, dynamic> && decoded['folders'] is List) {
      list = decoded['folders'] as List;
    } else if (decoded is Map<String, dynamic>) {
      list = [decoded];
    } else {
      throw Exception('分类配置必须为数组或包含 folders 字段的对象');
    }

    final existingFolders = await _folderRepo.getByType(type);
    final existingMap = {for (final f in existingFolders) f.id: f};
    int count = 0;

    for (int i = 0; i < list.length; i++) {
      final item = list[i];
      if (item is! Map<String, dynamic>) continue;
      final map = Map<String, dynamic>.from(item);
      final rawName = (map['name'] ?? map['title'] ?? '').toString().trim();
      if (rawName.isEmpty) continue;

      final id = map['id']?.toString() ?? const Uuid().v4();
      final parentId = map['parentId']?.toString() ?? map['parent_id']?.toString();
      final sortOrder = (map['sortOrder'] ?? map['sort_order'] as num?)?.toInt() ?? i;
      final isExpanded = map['isExpanded'] != false && map['is_expanded'] != 0;
      final now = DateTime.now();

      final folder = Folder(
        id: id,
        name: rawName,
        parentId: parentId,
        type: type,
        sortOrder: sortOrder,
        isExpanded: isExpanded,
        createdAt: existingMap[id]?.createdAt ?? now,
        updatedAt: now,
      );

      if (existingMap.containsKey(id)) {
        await _folderRepo.update(folder);
      } else {
        await _folderRepo.insert(folder);
      }
      count++;
    }

    WorkspaceEventBus.instance.emit(path, WorkspaceChangeType.updated, {'type': type, 'count': count});
    return {'status': 'updated', 'path': path, 'type': type, 'count': count};
  }

  Future<Map<String, dynamic>> _writeChatsFile(String path, String content) async {
    final name = path.substring('/chats/'.length).trim();
    if (name != 'sessions.json') {
      throw Exception('不支持修改的会话文件: $path');
    }

    dynamic decoded;
    try {
      decoded = jsonDecode(content);
    } catch (e) {
      throw Exception('会话配置必须为合法 JSON 格式: $e');
    }

    List<dynamic> list;
    if (decoded is List) {
      list = decoded;
    } else if (decoded is Map<String, dynamic> && decoded['sessions'] is List) {
      list = decoded['sessions'] as List;
    } else if (decoded is Map<String, dynamic>) {
      list = [decoded];
    } else {
      throw Exception('会话配置必须为数组或包含 sessions 字段的对象');
    }

    int updatedCount = 0;
    for (final item in list) {
      if (item is! Map<String, dynamic>) continue;
      final id = item['id']?.toString();
      final newTitle = item['title']?.toString()?.trim();
      if (id == null || id.isEmpty || newTitle == null || newTitle.isEmpty) continue;

      final existing = await _configRepo.getChatSession(id);
      if (existing != null) {
        final updated = existing.copyWith(
          title: newTitle,
          updatedAt: DateTime.now(),
        );
        await _configRepo.updateChatSession(updated);
        updatedCount++;
      }
    }

    WorkspaceEventBus.instance.emit('/chats/sessions.json', WorkspaceChangeType.updated, {'count': updatedCount});
    return {'status': 'updated', 'path': path, 'updated_count': updatedCount};
  }

  /// 颜色解析辅助方法（支持 hex #RRGGBB、#AARRGGBB 与常见颜色别名）
  Color? _parseColor(dynamic raw) {
    if (raw == null) return null;
    if (raw is int) return Color(raw);
    if (raw is String) {
      final s = raw.trim().toLowerCase();
      if (s == 'classic_blue' || s == 'blue' || s == '经典蓝') return const Color(0xFF005BCB);
      if (s == 'yellow_green' || s == '荧光黄绿') return const Color(0xFFC5E803);
      if (s == 'pink' || s == 'rose' || s == '玫瑰粉红') return const Color(0xFFE91E8C);
      if (s == 'green' || s == '春天亮绿') return const Color(0xFF00E676);
      var hex = s.replaceAll('#', '').replaceAll('0x', '');
      if (hex.length == 6) hex = 'ff$hex';
      if (hex.length == 8) {
        final val = int.tryParse(hex, radix: 16);
        if (val != null) return Color(val);
      }
    }
    return null;
  }

  /// 将 Color 转为标准 #RRGGBB 十六进制字符串
  String _colorToHex(Color color) {
    final rgb = color.toARGB32() & 0x00FFFFFF;
    return '#${rgb.toRadixString(16).padLeft(6, '0').toUpperCase()}';
  }

  /// 解析 ThemeMode（支持 system, light, dark 及其中文别名）
  ThemeMode _parseThemeMode(dynamic raw) {
    if (raw == null) return ThemeMode.system;
    final s = raw.toString().trim().toLowerCase();
    if (s == 'dark' || s == '深色' || s == '暗色' || s == '夜间' || s == '黑') return ThemeMode.dark;
    if (s == 'light' || s == '浅色' || s == '明亮' || s == '日间' || s == '白') return ThemeMode.light;
    return ThemeMode.system;
  }

  /// 将 ThemeMode 转为字符串
  String _themeModeToString(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.dark:
        return 'dark';
      case ThemeMode.light:
        return 'light';
      case ThemeMode.system:
        return 'system';
    }
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
    // 撤回录制：捕获替换前的旧状态（后续 writeFile 入口的捕获会同路径去重）
    await _captureUndoState(path);
    final rawLines = (await readFile(path)).split('\n');
    // 去掉行号前缀：锚定"行首数字+制表符"，避免误伤正文中含制表符的内容
    final originalContent = rawLines
        .map((l) => l.replaceFirst(RegExp(r'^\d+\t'), ''))
        .join('\n');

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
    // 撤回录制：先捕获删除前的旧状态（目录路径 readFile 会失败记为不存在，
    // 由下方目录分支对被连坐软删的实体逐一补捕获）
    await _captureUndoState(path);

    if (path.startsWith('/todos/')) {
      // 1. 如果路径是分类目录（以 '/' 结尾或没有 .md 后缀）
      if (!path.endsWith('.md')) {
        final folderName = path.substring('/todos/'.length).replaceAll('/', '').trim();
        final folders = await _folderRepo.getByType('todo');
        final matched = folders.where((f) => f.name == folderName || f.id == folderName).firstOrNull;
        if (matched != null) {
          if (matched.id == 'todo_default_today' || matched.id == 'todo_default_longterm') {
            throw Exception('系统默认分类不可删除: ${matched.name}');
          }
          final allTodos = await _todoRepo.getAll();
          int deletedCount = 0;
          for (final t in allTodos.where((t) => t.folderId == matched.id)) {
            // 连坐软删的每个待办单独捕获快照，撤回时可逐一还原
            await _captureUndoState('/todos/${matched.name}/${t.id}.md');
            await _todoRepo.softDelete(t.id);
            deletedCount++;
          }
          // 分类本身为硬删除，捕获分类清单快照以便撤回时重建
          await _captureUndoState('/folders/todos.json');
          await _folderRepo.delete(matched.id);
          WorkspaceEventBus.instance.emit(path, WorkspaceChangeType.deleted, matched);
          WorkspaceEventBus.instance.emit('/folders/todos.json', WorkspaceChangeType.updated, matched);
          return {'status': 'deleted', 'path': path, 'folder': matched.name, 'todos_deleted': deletedCount};
        }
      }

      // 2. 单个待办文件删除
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
      // 1. 如果路径是笔记本分类目录（以 '/' 结尾或没有 .md 后缀）
      if (!path.endsWith('.md')) {
        final folderName = path.substring('/notes/'.length).replaceAll('/', '').trim();
        final folders = await _folderRepo.getByType('note');
        final matched = folders.where((f) => f.name == folderName || f.id == folderName).firstOrNull;
        if (matched != null) {
          final allNotes = await _noteRepo.getAll();
          int deletedCount = 0;
          for (final n in allNotes.where((n) => n.folderId == matched.id)) {
            // 连坐软删的每个笔记单独捕获快照，撤回时可逐一还原
            await _captureUndoState('/notes/${matched.name}/${n.id}.md');
            await _noteRepo.softDelete(n.id);
            deletedCount++;
          }
          // 分类本身为硬删除，捕获分类清单快照以便撤回时重建
          await _captureUndoState('/folders/notes.json');
          await _folderRepo.delete(matched.id);
          WorkspaceEventBus.instance.emit(path, WorkspaceChangeType.deleted, matched);
          WorkspaceEventBus.instance.emit('/folders/notes.json', WorkspaceChangeType.updated, matched);
          return {'status': 'deleted', 'path': path, 'folder': matched.name, 'notes_deleted': deletedCount};
        }
      }

      // 2. 单个笔记文件删除
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

    if (path.startsWith('/journal/')) {
      final dateStr = path.substring('/journal/'.length).replaceAll('.md', '').trim();
      DateTime date;
      try {
        date = DateTime.parse(dateStr);
      } catch (_) {
        date = DateTime.now();
      }
      final existing = await _journalService.getNoteForDate(date);
      if (existing == null || existing.content.trim().isEmpty) {
        throw Exception('日期 $dateStr 尚未记录日记，无需删除');
      }
      await _journalService.saveJournal(date, '');
      WorkspaceEventBus.instance.emit(path, WorkspaceChangeType.deleted, {'date': dateStr, 'id': existing.id});
      return {
        'status': 'deleted',
        'path': path,
        'id': existing.id,
        'title': '$dateStr 日记',
      };
    }

    if (path.startsWith('/timeline/')) {
      final subPath = path.substring('/timeline/'.length).replaceAll('.md', '').trim();
      final dateRegex = RegExp(r'^\d{4}-\d{2}-\d{2}$');

      // 1. 如果路径是按日期格式（如 /timeline/2026-09-11.md），则删除该整天所有时间线记录
      if (dateRegex.hasMatch(subPath)) {
        final date = DateTime.parse(subPath);
        final records = await _diaryRepo.getByDate(date);
        if (records.isEmpty) {
          throw Exception('日期 $subPath 暂无流水事件打卡，无需删除');
        }
        for (final r in records) {
          await _diaryRepo.softDelete(r.id);
        }
        WorkspaceEventBus.instance.emit(path, WorkspaceChangeType.deleted, {'date': subPath, 'count': records.length});
        return {
          'status': 'deleted',
          'path': path,
          'title': '$subPath 时间线流水',
          'records_deleted': records.length,
        };
      }

      // 2. 如果路径包含单条记录 ID（如 /timeline/2026-09-11/<id>.md 或 /timeline/<id>.md）
      final segments = subPath.split('/');
      final recordId = segments.last.trim();
      if (recordId.isNotEmpty) {
        final record = await _diaryRepo.getById(recordId);
        if (record != null) {
          await _diaryRepo.softDelete(record.id);
          WorkspaceEventBus.instance.emit(path, WorkspaceChangeType.deleted, record);
          return {
            'status': 'deleted',
            'path': path,
            'id': record.id,
            'title': record.title,
            'time': record.time.toIso8601String(),
          };
        }
      }

      throw Exception('未找到对应的时间线记录或无效的日期路径: $path (必须为 /timeline/YYYY-MM-DD.md 或 /timeline/<id>.md)');
    }

    if (path.startsWith('/memory/')) {
      final category = AgentMemoryCategory.fromPath(path);
      if (category == null) {
        throw Exception('未知的记忆文件: $path（仅支持 /memory/user.md 与 /memory/agent.md）');
      }
      // 删除记忆文档 = 清空全部条目（保留分类本身，可随时重新写入）
      await _configRepo.saveAgentMemory(
        AgentMemoryDocument(category: category, content: ''),
      );
      WorkspaceEventBus.instance.emit(path, WorkspaceChangeType.deleted, {'category': category});
      return {
        'status': 'deleted',
        'path': path,
        'title': '${AgentMemoryCategory.displayName(category)}已清空',
      };
    }

    if (path.startsWith('/chats/')) {
      final segments = path.substring('/chats/'.length).split('/');
      final id = segments.last.replaceAll('.json', '').trim();
      if (id.isNotEmpty) {
        await _configRepo.softDeleteChatSession(id);
        WorkspaceEventBus.instance.emit('/chats/sessions.json', WorkspaceChangeType.deleted, {'id': id});
        return {'status': 'deleted', 'path': path, 'id': id};
      }
      throw Exception('未指定要删除的会话 ID: $path (例如: /chats/<session_id>.json)');
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

    // 检索 timeline
    final timelineRecords = await _diaryRepo.getAll();
    for (final r in timelineRecords) {
      if (reg.hasMatch(r.title) || reg.hasMatch(r.content) || reg.hasMatch(r.displayTag)) {
        final dateStr = r.time.toIso8601String().substring(0, 10);
        final timeStr = '${r.time.hour.toString().padLeft(2, '0')}:${r.time.minute.toString().padLeft(2, '0')}';
        results.add({
          'path': '/timeline/$dateStr.md',
          'line': 1,
          'match': '[$timeStr] ${r.displayTag} - ${r.title}',
          'type': 'timeline',
          'id': r.id,
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
