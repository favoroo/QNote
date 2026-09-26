import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:qnote_flutter/core/agent/prompts/q_personalities.dart';
import 'package:qnote_flutter/core/agent/services/q_personality_service.dart';
import 'package:qnote_flutter/core/agent/services/quick_prompt_service.dart';
import 'package:qnote_flutter/core/agent/skills/skill_registry.dart';
import 'package:qnote_flutter/core/agent/vfs/workspace_event_bus.dart';
import 'package:qnote_flutter/core/agent/vfs/workspace_undo_entry.dart';
import 'package:qnote_flutter/core/ai/free_model_service.dart';
import 'package:qnote_flutter/core/health/health_sync_service.dart';
import 'package:qnote_flutter/core/health/screen_usage_service.dart';
import 'package:qnote_flutter/core/notification/notification_service.dart';
import 'package:qnote_flutter/core/storage/color_mark_repository.dart';
import 'package:qnote_flutter/core/storage/config_repository.dart';
import 'package:qnote_flutter/core/storage/daily_score_repository.dart';
import 'package:qnote_flutter/core/storage/daily_score_service.dart';
import 'package:qnote_flutter/core/storage/database_helper.dart';
import 'package:qnote_flutter/core/storage/diary_repository.dart';
import 'package:qnote_flutter/core/storage/fixed_event_repository.dart';
import 'package:qnote_flutter/core/storage/folder_repository.dart';
import 'package:qnote_flutter/core/storage/health_metric_repository.dart';
import 'package:qnote_flutter/core/storage/journal_service.dart';
import 'package:qnote_flutter/core/utils/daily_score_adjust.dart';
import 'package:qnote_flutter/core/storage/note_repository.dart';
import 'package:qnote_flutter/core/storage/todo_repository.dart';
import 'package:qnote_flutter/core/utils/reminder_utils.dart';
import 'package:qnote_flutter/models/agent_memory.dart';
import 'package:qnote_flutter/models/agent_skill.dart';
import 'package:qnote_flutter/models/ai_roles.dart';
import 'package:qnote_flutter/models/date_color_mark.dart';
import 'package:qnote_flutter/models/diary_record.dart';
import 'package:qnote_flutter/models/fixed_event_template.dart';
import 'package:qnote_flutter/models/folder.dart';
import 'package:qnote_flutter/models/free_model_config.dart';
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
  final HealthMetricRepository _healthRepo = HealthMetricRepository(
    DatabaseHelper.instance,
  );
  final ScreenUsageService _screenUsageService = ScreenUsageService();
  final SkillRegistry _skillRegistry = SkillRegistry.instance;

  // ==========================================
  // 变更录制（对话轮次级撤销快照，支撑小Q对话的撤回/再次编辑）
  // ==========================================
  /// 录制句柄 → 该任务捕获的变更缓冲；句柄制使 AI 主会话与悬浮小Q任务可并发录制互不污染
  final Map<int, List<WorkspaceUndoEntry>> _recorders = {};
  int _recorderSeq = 0;

  /// 范围批量调整历史评分的只写端点
  static const String kStatsAdjustPath = '/stats/adjust.json';

  /// 精简评分索引：只含分值与维度、不含评语，供跨较长区间快速定位
  static const String kStatsScoreIndexPath = '/stats/score_index.json';

  /// 可录制的业务路径前缀；/chats/ 涉及会话自身（撤回时消息正在截断落库），跳过录制
  static const List<String> _recordablePrefixes = [
    '/todos/',
    '/notes/',
    '/timeline/',
    '/journal/',
    '/settings/',
    '/folders/',
    '/memory/',
    '/skills/',
    '/stats/',
    '/quick_prompts/',
  ];

  /// /settings/ 下全部可读写的配置文件（目录列举、grep 检索、追加模式禁用判定共用）
  static const List<String> _settingsFileNames = [
    'appearance.json',
    'ai.json',
    'personality.json',
    'shortcuts.json',
    'fixed_events.json',
    'profile.json',
    'weight.json',
    'health.json',
    'color_marks.json',
    'webdav.json',
  ];

  /// 统一日期格式化（YYYY-MM-DD），供时间线/日记路径拼接使用
  static String _formatDate(DateTime date) {
    final y = date.year.toString().padLeft(4, '0');
    final m = date.month.toString().padLeft(2, '0');
    final d = date.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  /// 剥离 [readFile] 添加的「行号 + 制表符」前缀，还原文件真实文本
  ///
  /// 与读取端共用同一条锚定规则（仅匹配行首数字+制表符），避免误伤正文里
  /// 本身含制表符的内容。edit_file 的参数清洗与追加写入的基底还原都依赖它。
  static String stripLineNumbers(String text) {
    return text
        .split('\n')
        .map((l) => l.replaceFirst(RegExp(r'^\d+\t'), ''))
        .join('\n');
  }

  /// 空态占位文案特征串：由读取端在「无数据/未编写」时生成，并非用户真实内容，
  /// 追加写入时必须整段丢弃，否则占位提示会被固化成正文
  static const List<String> placeholderMarkers = [
    '暂无流水事件打卡',
    '尚未开始编写这天的深度反思日记',
    '暂无记忆条目',
    '当天暂无生活评分记录',
    '暂无常用提示词',
  ];

  /// 判断读取结果是否为空态占位文案（无真实内容的端点）
  static bool isPlaceholderText(String content) =>
      placeholderMarkers.any(content.contains);

  /// 路径末段是否为实体 id（UUID 形态）：用于识别 canonical 路径
  /// （`/todos/<分类>/<id>.md`、`/notes/<id>.md`）并做 id 路径命中与脏数据防护
  static final RegExp _uuidPathSegment = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
    r'[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  );

  /// 支持追加模式（mode: append）的路径前缀：文本累积型端点
  ///
  /// JSON 配置类端点（/settings/、/folders/、/chats/）追加会写出非法 JSON，
  /// 因此不在支持范围内，由 [_mergeAppendContent] 显式拒绝并引导改用全量覆写。
  static const List<String> _appendablePrefixes = [
    '/todos/',
    '/notes/',
    '/timeline/',
    '/journal/',
    '/memory/',
    '/quick_prompts/',
  ];

  /// 追加写入的内容合并：读取既有真实内容后与新内容拼接
  ///
  /// 相比「先 read_file 再全量 write_file」的两步写法，追加模式由 VFS 内部完成
  /// 读取与合并：既省掉一轮工具调用，也避免模型覆写时漏掉时间线的
  /// `<!-- id: xxx -->` 注释而造成事件重复创建。
  Future<String> _mergeAppendContent(String path, String content) async {
    if (!_appendablePrefixes.any(path.startsWith)) {
      throw Exception(
        '路径 $path 不支持追加模式（仅待办、笔记、时间线、日记、记忆支持），请改用全量覆写：mode="overwrite"',
      );
    }
    final incoming = content.trimRight();
    if (incoming.isEmpty) return content;

    String existing = '';
    try {
      existing = stripLineNumbers(await readFile(path)).trimRight();
    } catch (_) {
      // 文件尚不存在（或读取失败）：追加等价于新建
      existing = '';
    }
    // 空态占位文案不是真实内容，不能作为追加基底
    if (existing.isEmpty || isPlaceholderText(existing)) return incoming;
    return '$existing\n\n$incoming';
  }

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

    // 范围调整端点自身读不出内容，快照挂在它上面会让撤回尝试删除一个不存在的
    // 虚拟文件；该端点的撤回由写库前逐天补捕的 /stats/scores/ 快照承担
    if (path == kStatsAdjustPath) return;

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
        final dateStr = path
            .substring('/journal/'.length)
            .replaceAll('.md', '')
            .trim();
        final date = DateTime.parse(dateStr);
        final existing = await _journalService.getNoteForDate(date);
        return WorkspaceUndoEntry(
          path: path,
          existedBefore: existing != null && existing.content.trim().isNotEmpty,
          beforeContent:
              (existing != null && existing.content.trim().isNotEmpty)
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
      // 时间线或评分空天文件的占位文案写回会被差量逻辑拒绝，按"本轮前不存在"处理
      final isEmptyPlaceholder =
          (path.startsWith('/timeline/') && before.contains('暂无流水事件打卡')) ||
          (path.startsWith('/stats/scores/') && before.contains('当天暂无生活评分记录'));
      return WorkspaceUndoEntry(
        path: path,
        existedBefore: !isEmptyPlaceholder,
        beforeContent: isEmptyPlaceholder ? null : before,
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
    final subPath = path
        .substring('/timeline/'.length)
        .replaceAll('.md', '')
        .trim();
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
    final titleWithExt = segments.length >= 2
        ? segments.sublist(1).join('/')
        : segments[0];
    final rawTitle = titleWithExt
        .replaceAll('.md', '')
        .replaceAll(RegExp(r'^\[[ x]\]\s*'), '')
        .trim();
    if (rawTitle.isEmpty) return null;
    try {
      final allTodos = await _todoRepo.getAll();
      final matched =
          allTodos.where((t) => t.id == rawTitle).firstOrNull ??
          allTodos.where((t) => t.title.trim() == rawTitle).firstOrNull;
      if (matched == null) return null;
      String folderName = '今日';
      final folders = await _folderRepo.getByType('todo');
      folderName =
          folders.where((f) => f.id == matched.folderId).firstOrNull?.name ??
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
      final matched =
          allNotes.where((n) => n.id == rawTitle).firstOrNull ??
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
- `/skills/`: 专业技能手册库（查阅对应领域的规范与操作手册）。内置技能只读；可通过 `write_file(path: "/skills/<名称>.md")` 创建或更新用户自定义技能（Markdown 手册，带 `name`/`description` frontmatter），删除自定义技能用 `delete_file`。
- `/memory/`: 小Q长期记忆（`user.md` 用户画像与习惯、`agent.md` 小Q手记；每次对话自动载入上下文，支持查看与增改）。
- `/quick_prompts/`: 常用提示词库（`prompts.md`，每行一条以 "- " 开头的提示词，对应输入框快捷填充项；支持全量覆写与追加，删除即清空全部）。
- `/todos/`: 待办事项库（目录名对应分类，如 `/todos/今日/`、`/todos/长期/`、`/todos/工作/`）。
- `/notes/`: 笔记与知识库（目录名对应笔记本，如 `/notes/技术架构/`。除 Markdown 外还支持写入 `.html` 网页、`.svg` 矢量图、`.json` 数据文件及常见代码文件，App 内会按后缀自动渲染预览；生成展示型内容（卡片、海报、可视化页面）时优先使用带内联样式的单文件 HTML，网页设计规范详见 `frontend-design` 技能）。
- `/timeline/`: 时间线流水日志（按日期归档，如 `/timeline/2026-09-11.md`，支持单点打卡与时间段打卡）。
- `/journal/`: 每日深度长篇日记与复盘（如 `/journal/2026-09-11.md`）。
- `/folders/`: 分类与笔记本层级管理（`todos.json` 待办分类、`notes.json` 笔记本目录，支持增删改查与重命名）。
- `/stats/`: 数据洞察与生活评分（`summary.json` 综合统计与完成率、`daily_scores.json` 近两周评分与建议、`score_index.json` 近一年评分索引（只有分值无评语）、`adjust.json` 按日期区间批量调整历史评分（只写）、`scores/YYYY-MM-DD.json` 单日评分读写）。
- `/health/`: 小米运动健康数据（`summary.json` 近期汇总、`YYYY-MM-DD.json` 单日步数/睡眠分期/心率曲线/血氧/压力/运动详情；撰写每日健康复盘与生活评分时可主动读取）。
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
    if (recursive) return _listDirRecursive(path);

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
        'health/',
        'chats/',
        'settings/',
        'quick_prompts/',
      ];
    }

    if (path == '/skills' || path == '/skills/') {
      return _skillRegistry.listSkills().map((s) => '${s['name']}.md').toList();
    }

    if (path == '/memory' || path == '/memory/') {
      return ['user.md', 'agent.md'];
    }

    if (path == '/quick_prompts' || path == '/quick_prompts/') {
      return ['prompts.md'];
    }

    if (path == '/folders' || path == '/folders/') {
      return ['todos.json', 'notes.json'];
    }

    if (path == '/stats' || path == '/stats/') {
      return [
        'summary.json',
        'screen_time.json',
        'daily_scores.json',
        'score_index.json',
        'adjust.json',
        'scores/',
      ];
    }

    if (path == '/health' || path == '/health/') {
      final recents = await _healthRepo.getRecentDailyMetrics(limit: 14);
      final files = <String>['summary.json'];
      for (final m in recents) {
        files.add('${m.date}.json');
      }
      return files;
    }

    if (path == '/stats/scores' || path == '/stats/scores/') {
      final now = DateTime.now();
      final startDate = DateTime(
        now.year,
        now.month,
        now.day,
      ).subtract(const Duration(days: DailyScoreService.maxAdjustRangeDays));
      final scores = await _dailyScoreRepo.getLatestByDateRange(startDate, now);
      return scores
          .map((s) => '${s.date.toIso8601String().substring(0, 10)}.json')
          .toList();
    }

    if (path == '/chats' || path == '/chats/') {
      return ['sessions.json'];
    }

    if (path == '/settings' || path == '/settings/') {
      return List<String>.from(_settingsFileNames);
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
      final folderName = path
          .substring('/todos/'.length)
          .replaceAll('/', '')
          .trim();
      final todos = await _todoRepo.getAll();
      final folders = await _folderRepo.getByType('todo');
      final matchedFolder = folders
          .where((f) => f.name.trim() == folderName)
          .firstOrNull;

      final matchedTodos = todos.where((t) {
        if (matchedFolder != null) {
          if (t.folderId == matchedFolder.id) return true;
        }
        // 若为今日，容错兜底未分类且非长期待办
        if (folderName == '今日' &&
            (t.folderId == null ||
                t.folderId!.isEmpty ||
                t.folderId == 'todo_default_today') &&
            !t.isLongTerm) {
          return true;
        }
        // 若为长期，容错兜底未分类长期待办
        if (folderName == '长期' &&
            (t.folderId == 'todo_default_longterm' ||
                (t.isLongTerm &&
                    (t.folderId == null || t.folderId!.isEmpty)))) {
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
      final rootNotes = notes
          .where((n) => n.folderId == null || n.folderId!.isEmpty)
          .toList();
      for (final n in rootNotes) {
        result.add('${n.title.trim().isEmpty ? "未命名笔记" : n.title}.md');
      }
      return result;
    }

    if (path.startsWith('/notes/')) {
      final folderName = path
          .substring('/notes/'.length)
          .replaceAll('/', '')
          .trim();
      final folders = await _folderRepo.getByType('note');
      final matchedFolder = folders
          .where((f) => f.name.trim() == folderName)
          .firstOrNull;
      if (matchedFolder == null) return [];

      final notes = await _noteRepo.getAll();
      final folderNotes = notes
          .where((n) => n.folderId == matchedFolder.id)
          .toList();
      return folderNotes
          .map((n) => '${n.title.trim().isEmpty ? "未命名笔记" : n.title}.md')
          .toList();
    }

    // 3. /timeline 目录
    if (path == '/timeline' || path == '/timeline/') {
      final now = DateTime.now();
      final dateSet = <String>{};
      for (int i = 0; i < 7; i++) {
        dateSet.add(_formatDate(now.subtract(Duration(days: i))));
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
        dates.add('${_formatDate(now.subtract(Duration(days: i)))}.md');
      }
      return dates;
    }

    return [];
  }

  /// 递归展开目录树，返回以 `/` 开头的完整虚拟路径（目录条目保留结尾 `/`）
  ///
  /// 采用广度优先：先把顶层各目录及其下一层铺开，再逐层深入。即便条目数达到
  /// [maxEntries] 被截断，当前目录的 children 也会完整展开完毕再停止——不会出现
  /// "看到了目录条目但看不到其下文件"的半截展开。
  Future<List<String>> _listDirRecursive(
    String root, {
    int maxEntries = 500,
  }) async {
    final result = <String>[];
    final queue = <String>[root];
    var truncated = false;
    while (queue.isNotEmpty && !truncated) {
      final dir = queue.removeAt(0);
      // 目录路径统一补足结尾斜杠，避免拼出 /todos//今日 这类双斜杠路径
      final base = dir.endsWith('/') ? dir : '$dir/';
      final children = await listDir(dir);
      for (final child in children) {
        final full = '$base$child';
        result.add(full);
        if (child.endsWith('/')) {
          queue.add(full);
        }
      }
      // 当前目录 children 全部展开完毕后再判断是否截断，避免半截子目录
      if (result.length >= maxEntries) {
        truncated = true;
      }
    }
    if (truncated) {
      result.add('... (目录条目过多，已截断前 ${result.length} 项)');
    }
    return result;
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
    } else if (path.startsWith('/quick_prompts/')) {
      fullContent = await _readQuickPromptsFile(path);
    } else if (path.startsWith('/folders/')) {
      fullContent = await _readFoldersFile(path);
    } else if (path.startsWith('/stats/')) {
      fullContent = await _readStatsFile(path);
    } else if (path.startsWith('/health/')) {
      fullContent = await _readHealthFile(path);
    } else if (path.startsWith('/chats/')) {
      fullContent = await _readChatsFile(path);
    } else if (path.startsWith('/settings/')) {
      fullContent = await _readSettingsFile(path);
    } else {
      throw Exception('未知的文件路径: $path');
    }

    // 处理行切片
    final lines = fullContent.split('\n');
    final start = (offset != null && offset > 0)
        ? (offset - 1).clamp(0, lines.length)
        : 0;
    final end = (limit != null && limit > 0)
        ? (start + limit).clamp(0, lines.length)
        : lines.length;

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
    final String titleWithExt = segments.length >= 2
        ? segments.sublist(1).join('/')
        : segments[0];
    final rawTitle = titleWithExt
        .replaceAll('.md', '')
        .replaceAll(RegExp(r'^\[[ x]\]\s*'), '')
        .trim();

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
    final dateStr = path
        .substring('/timeline/'.length)
        .replaceAll('.md', '')
        .trim();
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
      final startStr =
          '${r.time.hour.toString().padLeft(2, '0')}:${r.time.minute.toString().padLeft(2, '0')}';
      String timeHeader = startStr;
      if (r.endTime != null) {
        final endStr =
            '${r.endTime!.hour.toString().padLeft(2, '0')}:${r.endTime!.minute.toString().padLeft(2, '0')}';
        timeHeader = '$startStr - $endStr';
      }

      buffer.writeln('## [$timeHeader] ${r.title} <!-- id: ${r.id} -->');
      buffer.writeln('- 分类: ${r.displayTag}');
      buffer.writeln('- 心情: ${r.mood}');
      if (r.weather.isNotEmpty) {
        buffer.writeln('- 天气: ${r.weather}');
      }
      if (r.photos.isNotEmpty) {
        // 仅路径文本模型无法感知画面，附提示引导其调用工具加载图片
        // （行尾括注由写回解析按「（可调用…）」剥离，改措辞要保持这个前缀）
        buffer.writeln('- 图片: ${r.photos.join(', ')}'
            '（可调用 view_image 查看画面；当前模型不支持看图时用 describe_image 取文字识别结果）');
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
    final dateStr = path
        .substring('/journal/'.length)
        .replaceAll('.md', '')
        .trim();
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

  /// 读取常用提示词列表，以 Markdown 列表格式返回
  Future<String> _readQuickPromptsFile(String path) async {
    final name = path.substring('/quick_prompts/'.length).trim();
    if (name != 'prompts.md' && name.isNotEmpty) {
      throw Exception('未知的提示词文件: $path（仅支持 /quick_prompts/prompts.md）');
    }
    final prompts = await QuickPromptService.instance.getPrompts();
    if (prompts.isEmpty) {
      return '# 常用提示词\n\n> 暂无常用提示词。可以通过 write_file / edit_file 写入，'
          '每行一条提示词（以 "- " 开头），即对应输入框的快捷填充内容。';
    }
    return prompts.map((p) => '- $p').join('\n');
  }

  Future<String> _readSettingsFile(String path) async {
    final name = path.substring('/settings/'.length).trim();
    if (name == 'appearance.json') {
      final prefs = await SharedPreferences.getInstance();
      final themeIndex = prefs.getInt('theme_mode') ?? 0;
      final themeMode =
          ThemeMode.values[themeIndex.clamp(0, ThemeMode.values.length - 1)];
      final accentVal = prefs.getInt('accent_color') ?? 0xFF005BCB;
      final colorHex = _colorToHex(Color(accentVal));
      final data = {
        'themeMode': _themeModeToString(themeMode),
        'accentColor': colorHex,
        'description':
            'themeMode 可选: "system" | "light" | "dark"；accentColor 为 16 进制颜色（如 #005BCB 经典蓝、#C5E803 荧光黄绿、#E91E8C 玫瑰粉红、#00E676 春天亮绿、#FF3B30 活力红、#FF9500 活力橙、#00BCD4 湖水青、#7C4DFF 典雅紫）',
      };
      return const JsonEncoder.withIndent('  ').convert(data);
    } else if (name == 'health.json') {
      final prefs = await SharedPreferences.getInstance();
      final stepTarget = prefs.getInt(HealthSyncService.keyDailyStepTarget) ??
          HealthSyncService.defaultDailyStepTarget;
      final autoSync = prefs.getBool(HealthSyncService.keyAutoSync) ?? true;
      final data = {
        'dailyStepTarget': stepTarget,
        'autoSync': autoSync,
        'description':
            'dailyStepTarget 为小米运动健康每日目标步数（1000-100000 的正整数）；autoSync 为启动时是否自动同步小米运动健康。修改后小米健康设置页与统计页生效。',
      };
      return const JsonEncoder.withIndent('  ').convert(data);
    } else if (name == 'ai.json') {
      final roles = await _configRepo.getAiRoles() ?? const AiRoles();
      final temps =
          await _configRepo.getAiTemperatures() ?? const AiTemperatures();
      final customConfigs = await _configRepo.getAllAiConfigs();
      final freeModels = await FreeModelService.instance.getCachedModels();
      final data = {
        'roles': {
          'assistant': {
            'useFreeModel': roles.assistantUseFreeModel,
            'freeModelId':
                roles.assistantFreeModelId ?? kDefaultFreeModelId,
            'customModelId': roles.assistant,
          },
          'timelineOptimization': {
            'useFreeModel': roles.timelineOptimizationUseFreeModel,
            'freeModelId':
                roles.timelineOptimizationFreeModelId ??
                kDefaultFreeModelId,
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
        'customModels': customConfigs
            .map(
              (c) => {
                'id': c.id,
                'name': c.name,
                'provider': c.provider,
                'baseUrl': c.baseUrl,
                'modelName': c.modelName,
                'isDefault': c.isDefault,
              },
            )
            .toList(),
        'availableFreeModels': freeModels
            .map(
              (m) => {
                'id': m.id,
                'displayName': m.displayName,
                'provider': m.provider,
                'modelName': m.modelName,
              },
            )
            .toList(),
      };
      return const JsonEncoder.withIndent('  ').convert(data);
    } else if (name == 'personality.json') {
      final service = QPersonalityService.instance;
      final data = {
        'activeId': await service.getActiveId(),
        'customPrompt': await service.getCustomPrompt(),
        'availablePersonalities': [
          for (final p in QPersonalities.presets)
            {'id': p.id, 'name': p.name, 'description': p.description},
        ],
        'description':
            'activeId 可选 default(经典管家) | energetic(活泼元气) | concise(简洁干练) | '
            'gentle(温柔陪伴) | custom(自定义)；选 custom 时在 customPrompt 提供人格描述（3~6 句），'
            '修改后下轮对话生效',
      };
      return const JsonEncoder.withIndent('  ').convert(data);
    } else if (name == 'shortcuts.json') {
      final shortcuts = await _configRepo.getAllShortcutConfigs();
      return const JsonEncoder.withIndent(
        '  ',
      ).convert(shortcuts.map((s) => s.toMap()).toList());
    } else if (name == 'fixed_events.json') {
      final templates = await FixedEventRepository.instance.getAll();
      final list = templates
          .map(
            (t) => {
              'id': t.id,
              'name': t.name,
              'isTimePoint': t.isTimePoint,
              'timePeriods': t.timePeriods
                  .map((p) => {'startTime': p.startTime, 'endTime': p.endTime})
                  .toList(),
              'content': t.content ?? '',
              'tags': t.tags,
              'sortOrder': t.sortOrder,
              'isEnabled': t.isEnabled,
            },
          )
          .toList();
      return const JsonEncoder.withIndent('  ').convert(list);
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
        'history': sortedHistory
            .map(
              (w) => {
                'id': w.id,
                'weight': w.weight,
                'time': w.time.toIso8601String(),
              },
            )
            .toList(),
      };
      return const JsonEncoder.withIndent('  ').convert(data);
    } else if (name == 'profile.json') {
      final profile = await _configRepo.getUserProfile();
      if (profile == null) {
        return const JsonEncoder.withIndent('  ').convert({'name': 'QNote 用户'});
      }
      final map = profile.toMap();
      try {
        if (map['weight_history'] is String &&
            (map['weight_history'] as String).isNotEmpty) {
          map['weight_history'] = jsonDecode(map['weight_history'] as String);
        }
      } catch (_) {}
      try {
        if (map['custom_fields'] is String &&
            (map['custom_fields'] as String).isNotEmpty) {
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
      return const JsonEncoder.withIndent(
        '  ',
      ).convert(webdav?.toMap() ?? {'enabled': false});
    }
    throw Exception('未知的配置文件: $path');
  }

  Future<String> _readFoldersFile(String path) async {
    final name = path.substring('/folders/'.length).trim();
    if (name == 'todos.json') {
      final folders = await _folderRepo.getByType('todo');
      return const JsonEncoder.withIndent('  ').convert(
        folders
            .map(
              (f) => {
                'id': f.id,
                'name': f.name,
                'sortOrder': f.sortOrder,
                'isExpanded': f.isExpanded,
              },
            )
            .toList(),
      );
    } else if (name == 'notes.json') {
      final folders = await _folderRepo.getByType('note');
      return const JsonEncoder.withIndent('  ').convert(
        folders
            .map(
              (f) => {
                'id': f.id,
                'name': f.name,
                'parentId': f.parentId,
                'sortOrder': f.sortOrder,
                'isExpanded': f.isExpanded,
              },
            )
            .toList(),
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
      final completionRate = totalTodos > 0
          ? '${(completedTodos / totalTodos * 100).toStringAsFixed(1)}%'
          : '0.0%';

      // 2. 近 7 天时间线统计
      final now = DateTime.now();
      final startDate = DateTime(
        now.year,
        now.month,
        now.day,
      ).subtract(const Duration(days: 6));
      final recentRecords = await _diaryRepo.getByDateRange(startDate, now);

      final categoryCounts = <String, int>{};
      int totalMood = 0;
      int moodRecordCount = 0;
      for (final r in recentRecords) {
        final cat = r.displayTag.isNotEmpty ? r.displayTag : '日常';
        categoryCounts[cat] = (categoryCounts[cat] ?? 0) + 1;
        if (r.mood > 0) {
          totalMood += r.mood;
          moodRecordCount++;
        }
      }

      final avgMood = moodRecordCount > 0
          ? (totalMood / moodRecordCount).toStringAsFixed(1)
          : '3.0';

      final data = {
        'timeRange':
            '${startDate.toIso8601String().substring(0, 10)} ~ ${now.toIso8601String().substring(0, 10)}',
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
    } else if (name == 'screen_time.json') {
      if (!_screenUsageService.isSupported) {
        return const JsonEncoder.withIndent('  ').convert({
          'supported': false,
          'hasPermission': false,
          'message': '当前运行平台不支持屏幕使用时长统计（该功能仅在 Android 设备上通过 UsageStatsManager 提供）。',
        });
      }
      final hasPerm = await _screenUsageService.hasPermission();
      if (!hasPerm) {
        return const JsonEncoder.withIndent('  ').convert({
          'supported': true,
          'hasPermission': false,
          'message': '手机尚未授予“有权查看使用情况的应用”权限。请引导用户在手机系统设置或 QNote 统计页开启权限后再次查看。',
        });
      }

      final todayUsage = await _screenUsageService.getTodayUsage(limit: 20);
      final weeklyList = await _screenUsageService.getWeeklyScreenTime();

      int totalWeeklyMinutes = 0;
      for (final item in weeklyList) {
        totalWeeklyMinutes += item.minutes;
      }
      final weeklyAvgMinutes = weeklyList.isNotEmpty ? (totalWeeklyMinutes / weeklyList.length).round() : 0;
      final weeklyAvgHours = weeklyAvgMinutes ~/ 60;
      final weeklyAvgMins = weeklyAvgMinutes % 60;
      final weeklyAvgText = weeklyAvgHours > 0 ? '$weeklyAvgHours小时$weeklyAvgMins分钟' : '$weeklyAvgMins分钟';

      final todayData = todayUsage != null
          ? {
              'date': _formatDate(DateTime.now()),
              'totalMinutes': todayUsage.totalMinutes,
              'formattedTotalTime': todayUsage.formattedTotalTime,
              'yesterdayTotalMinutes': todayUsage.yesterdayTotalTimeMs ~/ 60000,
              'diffWithYesterdayMs': todayUsage.diffWithYesterdayMs,
              'diffDescription': todayUsage.diffDescription,
              'appCount': todayUsage.appList.length,
              'topApps': todayUsage.appList
                  .map(
                    (app) => {
                      'appName': app.appName.isEmpty ? app.packageName : app.appName,
                      'packageName': app.packageName,
                      'minutes': app.minutes,
                      'formattedDuration': app.formattedDuration,
                      'lastTimeUsed': app.lastTimeUsedMs > 0
                          ? DateTime.fromMillisecondsSinceEpoch(app.lastTimeUsedMs).toIso8601String()
                          : null,
                    },
                  )
                  .toList(),
            }
          : null;

      final weeklyData = weeklyList
          .map(
            (item) => {
              'date': _formatDate(item.date),
              'dayLabel': item.dayLabel,
              'totalMinutes': item.minutes,
              'hours': double.parse(item.hours.toStringAsFixed(1)),
              'isToday': item.isToday,
            },
          )
          .toList();

      final data = {
        'supported': true,
        'hasPermission': true,
        'today': todayData,
        'weekly': weeklyData,
        'totalWeeklyMinutes': totalWeeklyMinutes,
        'weeklyAverageMinutes': weeklyAvgMinutes,
        'weeklyFormattedAverage': weeklyAvgText,
      };
      return const JsonEncoder.withIndent('  ').convert(data);
    } else if (name == 'score_index.json') {
      final now = DateTime.now();
      final startDate = DateTime(
        now.year,
        now.month,
        now.day,
      ).subtract(const Duration(days: 366));
      final scores = await _dailyScoreRepo.getLatestByDateRange(startDate, now);
      // 刻意省略 summary/suggestions：单日评语就要几百 token，一年的索引会把上下文灌满；
      // 要看评语原文再按天读 /stats/scores/YYYY-MM-DD.json
      final list = scores
          .map(
            (s) => {
              'date': s.date.toIso8601String().substring(0, 10),
              'totalScore': s.totalScore,
              'dimensionScores': s.dimensionScores,
              'recordCount': s.recordCount,
            },
          )
          .toList();
      return const JsonEncoder.withIndent('  ').convert(list);
    } else if (name == 'daily_scores.json') {
      final now = DateTime.now();
      final startDate = DateTime(
        now.year,
        now.month,
        now.day,
      ).subtract(const Duration(days: 14));
      final scores = await _dailyScoreRepo.getByDateRange(startDate, now);
      final list = scores
          .map(
            (s) => {
              'date': s.date.toIso8601String().substring(0, 10),
              'totalScore': s.totalScore,
              'dimensionScores': s.dimensionScores,
              'summary': s.summary,
              'suggestions': s.suggestions,
              'recordCount': s.recordCount,
            },
          )
          .toList();
      return const JsonEncoder.withIndent('  ').convert(list);
    } else if (path.startsWith('/stats/scores/')) {
      final dateStr = path
          .substring('/stats/scores/'.length)
          .replaceAll('.json', '')
          .trim();
      DateTime date;
      try {
        date = DateTime.parse(dateStr);
      } catch (_) {
        throw Exception('无效的评分日期格式: $dateStr（正确格式应为 YYYY-MM-DD.json）');
      }
      final score = await _dailyScoreRepo.getByDate(date);
      if (score == null) {
        return '{\n  "date": "$dateStr",\n  "status": "not_scored",\n  "message": "当天暂无生活评分记录。可以通过 write_file(path: \\"/stats/scores/$dateStr.json\\") 进行评分。"\n}';
      }
      final data = {
        'id': score.id,
        'date': score.date.toIso8601String().substring(0, 10),
        'totalScore': score.totalScore,
        'dimensionScores': score.dimensionScores,
        'summary': score.summary,
        'suggestions': score.suggestions,
        'recordCount': score.recordCount,
        'createdAt': score.createdAt.toIso8601String(),
        'updatedAt': score.updatedAt.toIso8601String(),
      };
      return const JsonEncoder.withIndent('  ').convert(data);
    }
    throw Exception('未知的统计数据路径: $path');
  }

  Future<String> _readHealthFile(String path) async {
    final sub = path.substring('/health/'.length).trim();
    if (sub == 'summary.json' || sub == 'recent.json') {
      final recents = await _healthRepo.getRecentDailyMetrics(limit: 7);
      final recentSports = await _healthRepo.getSportRecords(limit: 10);
      return const JsonEncoder.withIndent('  ').convert({
        'description': '小米运动健康最近同步汇总',
        'recent_daily_metrics': recents
            .map(
              (m) => {
                'date': m.date,
                'steps': m.steps,
                'calories_kcal': m.calories,
                'sleep_duration_min': m.sleepDurationMinutes,
                'sleep_score': m.sleepScore,
                'avg_heart_rate': m.avgHeartRate,
                'resting_heart_rate': m.restingHeartRate,
                'avg_spo2': m.avgSpo2,
                'avg_stress': m.avgStress,
              },
            )
            .toList(),
        'recent_sports': recentSports
            .map(
              (s) => {
                'title': s.title,
                'category': s.category,
                'start_time': s.startTime.toIso8601String(),
                'duration_min': s.durationSeconds ~/ 60,
                'distance_km': (s.distanceMeters / 1000).toStringAsFixed(2),
                'calories_kcal': s.calories,
                'avg_pace': s.avgPace,
                'avg_hr': s.avgHeartRate,
              },
            )
            .toList(),
      });
    }

    final dateStr = sub.replaceAll('.json', '').replaceAll('.md', '').trim();
    final metric = await _healthRepo.getDailyMetrics(dateStr);
    final sports = await _healthRepo.getSportRecordsByDate(dateStr);

    if (metric == null && sports.isEmpty) {
      return const JsonEncoder.withIndent('  ').convert({
        'date': dateStr,
        'has_data': false,
        'message': '该日期暂无同步的小米运动健康数据',
      });
    }

    return const JsonEncoder.withIndent('  ').convert({
      'date': dateStr,
      'has_data': true,
      if (metric != null) ...{
        'steps': metric.steps,
        'distance_km': (metric.distanceMeters / 1000).toStringAsFixed(2),
        'calories_kcal': metric.calories,
        'active_minutes': metric.activeMinutes,
        'sleep': {
          'duration_min': metric.sleepDurationMinutes,
          'deep_sleep_min': metric.deepSleepMinutes,
          'light_sleep_min': metric.lightSleepMinutes,
          'rem_sleep_min': metric.remSleepMinutes,
          'awake_min': metric.awakeMinutes,
          'start_time': metric.sleepStartTime,
          'end_time': metric.sleepEndTime,
          'score': metric.sleepScore,
        },
        'heart_rate': {
          'avg_bpm': metric.avgHeartRate,
          'max_bpm': metric.maxHeartRate,
          'min_bpm': metric.minHeartRate,
          'resting_bpm': metric.restingHeartRate,
        },
        'spo2': {'avg_percent': metric.avgSpo2, 'min_percent': metric.minSpo2},
        'stress': {'avg': metric.avgStress, 'max': metric.maxStress},
      },
      'sports': sports
          .map(
            (s) => {
              'title': s.title,
              'category': s.category,
              'start_time': s.startTime.toIso8601String(),
              'end_time': s.endTime.toIso8601String(),
              'duration_min': s.durationSeconds ~/ 60,
              'distance_km': (s.distanceMeters / 1000).toStringAsFixed(2),
              'calories_kcal': s.calories,
              'avg_pace': s.avgPace,
              'avg_hr': s.avgHeartRate,
              'steps': s.steps,
            },
          )
          .toList(),
    });
  }

  Future<String> _readChatsFile(String path) async {
    final name = path.substring('/chats/'.length).trim();
    if (name == 'sessions.json') {
      final sessions = await _configRepo.getAllChatSessions();
      final list = sessions
          .map(
            (s) => {
              'id': s.id,
              'title': s.title,
              'messageCount': s.messages.length,
              'createdAt': s.createdAt.toIso8601String(),
              'updatedAt': s.updatedAt.toIso8601String(),
            },
          )
          .toList();
      return const JsonEncoder.withIndent('  ').convert(list);
    }
    throw Exception('未知的会话管理文件: $path');
  }

  /// 写入/新建虚拟文件
  ///
  /// [append] 为 true 时进入追加模式：VFS 内部读取既有内容后拼接（见
  /// [_mergeAppendContent]），仅文本累积型端点支持。
  Future<Map<String, dynamic>> writeFile(
    String rawPath,
    String content, {
    bool append = false,
  }) async {
    final path = normalizePath(rawPath);
    final effectiveContent = append
        ? await _mergeAppendContent(path, content)
        : content;
    // 撤回录制：捕获本轮首次修改前的旧状态（editFile 内部最终也走 writeFile，靠同路径去重）
    await _captureUndoState(path);

    if (path.startsWith('/todos/')) {
      return await _writeTodoFile(path, effectiveContent);
    } else if (path.startsWith('/notes/')) {
      return await _writeNoteFile(path, effectiveContent);
    } else if (path.startsWith('/timeline/')) {
      return await _writeTimelineFile(path, effectiveContent);
    } else if (path.startsWith('/journal/')) {
      return await _writeJournalFile(path, effectiveContent);
    } else if (path.startsWith('/memory/')) {
      return await _writeMemoryFile(path, effectiveContent);
    } else if (path.startsWith('/quick_prompts/')) {
      return await _writeQuickPromptsFile(path, effectiveContent);
    } else if (path.startsWith('/skills/')) {
      return await _writeSkillFile(path, effectiveContent);
    } else if (path.startsWith('/folders/')) {
      return await _writeFoldersFile(path, effectiveContent);
    } else if (path.startsWith('/chats/')) {
      return await _writeChatsFile(path, effectiveContent);
    } else if (path.startsWith('/settings/')) {
      return await _writeSettingsFile(path, effectiveContent);
    } else if (path.startsWith('/stats/')) {
      return await _writeStatsFile(path, effectiveContent);
    }
    throw Exception('不支持写入只读或未知的路径: $path');
  }

  Future<Map<String, dynamic>> _writeTodoFile(
    String path,
    String content,
  ) async {
    final segments = path.substring('/todos/'.length).split('/');
    String folderName = '今日';
    String titleWithExt = '';
    if (segments.length >= 2) {
      folderName = segments[0].trim();
      titleWithExt = segments.sublist(1).join('/');
    } else {
      titleWithExt = segments[0];
    }
    final title = titleWithExt
        .replaceAll('.md', '')
        .replaceAll(RegExp(r'^\[[ x]\]\s*'), '')
        .trim();

    // 1. 解析 Frontmatter
    final parsed = _parseFrontmatter(content);
    final meta = parsed.meta;
    final description = parsed.body.trim();

    final status = (meta['status'] as String? ?? '').toLowerCase();
    final isCompleted =
        status == 'completed' || status == 'done' || path.contains('[x]');
    final rawPriority = (meta['priority'] as String? ?? 'normal').toLowerCase();
    final priority = (rawPriority == 'important' || rawPriority == 'high')
        ? 'important'
        : 'normal';
    final isLongTerm = meta['is_long_term'] == true || folderName == '长期';

    // 重复规则
    final rawRepeat = (meta['repeat_rule'] ?? meta['repeat'] ?? '')
        .toString()
        .trim()
        .toLowerCase();
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
    } else if ([
      'daily',
      'workday',
      'weekly',
      'monthly',
      'yearly',
      'none',
    ].contains(rawRepeat)) {
      repeatRule = rawRepeat;
    }

    // 标签
    String tags = '';
    if (meta['tags'] != null) {
      if (meta['tags'] is List) {
        tags = (meta['tags'] as List).map((e) => e.toString().trim()).join(',');
      } else {
        tags = meta['tags']
            .toString()
            .replaceAll('[', '')
            .replaceAll(']', '')
            .replaceAll('"', '')
            .trim();
      }
    }

    DateTime? dueDate;
    if (meta['due_date'] != null) {
      try {
        dueDate = DateTime.parse(
          meta['due_date'].toString().replaceAll('"', ''),
        );
      } catch (_) {}
    }

    // 提醒时间：归一化为 MM-DD HH:mm 存储，这是一切通知的唯一触发源
    // （due_date 仅作记录，不会触发通知、应用内也不展示）
    final String? reminderTime = ReminderUtils.normalize(
      meta['reminder_time'] ?? meta['remind_at'] ?? meta['reminder'],
    );

    // 2. 解析或自动创建分类
    final folderId = await _resolveTodoFolder(
      folderName,
      isLongTerm: isLongTerm,
    );

    // 3. 判断是更新还是创建
    final allTodos = await _todoRepo.getAll();
    final existingId = meta['id']?.toString().replaceAll('"', '');
    Todo? existing;
    if (existingId != null && existingId.isNotEmpty) {
      existing = allTodos.where((t) => t.id == existingId).firstOrNull;
      // 撤回恢复场景：id 命中已软删除的记录时复活，否则被删待办写回后仍然不可见
      if (existing == null) {
        final allWithDeleted = await _todoRepo.getAll(includeDeleted: true);
        existing = allWithDeleted
            .where((t) => t.id == existingId && t.isDeleted)
            .firstOrNull;
      }
    }
    existing ??= allTodos
        .where((t) => t.title.trim() == title && t.folderId == folderId)
        .firstOrNull;

    // 路径末段直接是实体 id 的 canonical 形态（/todos/<分类>/<id>.md：grep 命中、撤回快照、
    // 页面上下文提示都会产出这种路径）。两条防护缺一不可：
    // 1) 必须命中既有实体，否则会新建一条 UUID 标题的脏待办；
    // 2) 标题必须沿用既有标题——撤回恢复的正文自带 `id:`，会先按 id 命中并原样保留路径末段
    //    作为新标题，若照写就会把 UUID 顶成标题（历史脏数据的真实成因）。
    final isEntityIdPath = _uuidPathSegment.hasMatch(title);
    if (existing == null && isEntityIdPath) {
      existing = allTodos.where((t) => t.id == title).firstOrNull;
      if (existing == null) {
        throw Exception('未找到待办: $path（路径末段为实体 id，但对应待办不存在，请先 grep 确认现状）');
      }
    }
    final effectiveTitle = isEntityIdPath ? existing!.title : title;

    final now = DateTime.now();
    if (existing != null) {
      final updated = existing.copyWith(
        title: effectiveTitle.isNotEmpty ? effectiveTitle : existing.title,
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
      WorkspaceEventBus.instance.emit(
        path,
        WorkspaceChangeType.updated,
        updated,
      );
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
        title: effectiveTitle,
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
      WorkspaceEventBus.instance.emit(
        path,
        WorkspaceChangeType.created,
        newTodo,
      );
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

  Future<String> _resolveTodoFolder(
    String folderName, {
    bool isLongTerm = false,
  }) async {
    final folders = await _folderRepo.getByType('todo');
    final trimmed = folderName.trim();

    if (trimmed == '今日' || trimmed == 'today') {
      final today = folders
          .where((f) => f.id == 'todo_default_today' || f.name == '今日')
          .firstOrNull;
      if (today != null) return today.id;
    }
    if (trimmed == '长期' || trimmed == 'longterm' || isLongTerm) {
      final longterm = folders
          .where((f) => f.id == 'todo_default_longterm' || f.name == '长期')
          .firstOrNull;
      if (longterm != null) return longterm.id;
    }

    final matched = folders
        .where((f) => f.name.toLowerCase() == trimmed.toLowerCase())
        .firstOrNull;
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

  /// 按名称解析笔记本目录 id，不存在则自动创建（写入与移动共用同一套归属规则）
  Future<String> _resolveOrCreateNoteFolder(String folderName) async {
    final trimmed = folderName.trim();
    final noteFolders = await _folderRepo.getByType('note');
    final matched = noteFolders.where((f) => f.name == trimmed).firstOrNull;
    if (matched != null) return matched.id;

    final now = DateTime.now();
    final newFolder = Folder(
      id: const Uuid().v4(),
      name: trimmed,
      type: 'note',
      sortOrder: noteFolders.length,
      createdAt: now,
      updatedAt: now,
    );
    await _folderRepo.insert(newFolder);
    return newFolder.id;
  }

  Future<Map<String, dynamic>> _writeNoteFile(
    String path,
    String content,
  ) async {
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

    final String? folderId = (folderName != null && folderName.isNotEmpty)
        ? await _resolveOrCreateNoteFolder(folderName)
        : null;

    final allNotes = await _noteRepo.getAll();
    final existingId = meta['id']?.toString().replaceAll('"', '');
    Note? existing;
    if (existingId != null && existingId.isNotEmpty) {
      existing = allNotes.where((n) => n.id == existingId).firstOrNull;
      // 撤回恢复场景：id 命中已软删除的记录时复活，否则被删笔记写回后仍然不可见
      if (existing == null) {
        final allWithDeleted = await _noteRepo.getAll(includeDeleted: true);
        existing = allWithDeleted
            .where((n) => n.id == existingId && n.isDeleted)
            .firstOrNull;
      }
    }
    existing ??= allNotes
        .where((n) => n.title.trim() == title && n.folderId == folderId)
        .firstOrNull;

    // 路径末段是笔记 id 的 canonical 形态（/notes/<id>.md）时，命中既有实体且标题沿用原值，
    // 避免把 id 顶成笔记标题（撤回恢复的正文自带 `id:`，重写路径时会走到这里）；
    // 原分类由下方 copyWith 的 `folderId ?? existing.folderId` 兜底保留
    final isEntityIdPath = _uuidPathSegment.hasMatch(title);
    if (existing == null && isEntityIdPath) {
      existing = allNotes.where((n) => n.id == title).firstOrNull;
      if (existing == null) {
        throw Exception('未找到笔记: $path（路径末段为实体 id，但对应笔记不存在，请先 grep 确认现状）');
      }
    }
    final effectiveTitle = isEntityIdPath ? existing!.title : title;

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
        title: effectiveTitle.isNotEmpty ? effectiveTitle : existing.title,
        content: noteContent,
        folderId: folderId ?? existing.folderId,
        isPinned: meta['pinned'] == true,
        tags: tagsStr.isNotEmpty ? tagsStr : existing.tags,
        images: extractedImages.isNotEmpty ? extractedImages : existing.images,
        isDeleted: false,
        updatedAt: now,
      );
      await _noteRepo.update(updated);
      WorkspaceEventBus.instance.emit(
        path,
        WorkspaceChangeType.updated,
        updated,
      );
      return {
        'status': 'updated',
        'path': path,
        'id': updated.id,
        'title': updated.title,
      };
    } else {
      final newNote = Note(
        id: const Uuid().v4(),
        title: effectiveTitle,
        content: noteContent,
        folderId: folderId,
        isPinned: meta['pinned'] == true,
        tags: tagsStr,
        images: extractedImages,
        createdAt: now,
        updatedAt: now,
      );
      await _noteRepo.insert(newNote);
      WorkspaceEventBus.instance.emit(
        path,
        WorkspaceChangeType.created,
        newNote,
      );
      return {
        'status': 'created',
        'path': path,
        'id': newNote.id,
        'title': newNote.title,
      };
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

  Future<Map<String, dynamic>> _writeTimelineFile(
    String path,
    String content,
  ) async {
    final dateStr = path
        .substring('/timeline/'.length)
        .replaceAll('.md', '')
        .trim();
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
      final inlineId = RegExp(
        r'<!--\s*id:\s*([^\s>]+)\s*-->',
      ).firstMatch(title);
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
      final explicitTags = <String>[];

      for (final line in body.split('\n')) {
        final l = line.trim().replaceAll('：', ':');
        if (l.startsWith('- 分类:') || l.startsWith('- category:')) {
          category = _fieldValue(l);
        } else if (l.startsWith('- 标签:') ||
            l.startsWith('- tags:') ||
            l.startsWith('- tag:')) {
          final tStr = _fieldValue(l);
          for (final part in tStr.split(RegExp('[,，、 ]+'))) {
            final t = part.trim();
            if (t.isNotEmpty && !explicitTags.contains(t)) {
              explicitTags.add(t);
            }
          }
        } else if (l.startsWith('- 心情:') || l.startsWith('- mood:')) {
          mood = int.tryParse(_fieldValue(l));
        } else if (l.startsWith('- 天气:') || l.startsWith('- weather:')) {
          weather = _fieldValue(l);
        } else if (l.startsWith('- 标记颜色:') ||
            l.startsWith('- 颜色标记:') ||
            l.startsWith('- color_mark:')) {
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
                hexColor =
                    '#${c.toARGB32().toRadixString(16).padLeft(8, '0').toUpperCase()}';
              }
            }
            _colorMarkRepo.insert(
              DateColorMark(
                id: const Uuid().v4(),
                date: baseDate,
                color: hexColor,
              ),
            );
            WorkspaceEventBus.instance.emit(
              '/settings/color_marks.json',
              WorkspaceChangeType.updated,
              {'date': dateStr, 'color': hexColor},
            );
          }
        } else if (l.startsWith('- 图片:') ||
            l.startsWith('- photo:') ||
            l.startsWith('- photos:')) {
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

      // 分类与标签规整化：如果分类仍为默认日常，但已提供标准语义分类或 explicitTags
      if (category == '日常' && explicitTags.isNotEmpty) {
        final stdCats = ['饮食', '活动', '睡眠', '健康', '记账'];
        for (final sc in stdCats) {
          if (explicitTags.contains(sc)) {
            category = sc;
            break;
          }
        }
      }

      // 饮食/活动常见二级字段标准化兼容：
      if (category == '饮食') {
        if (!customFields.containsKey('rating') &&
            !customFields.containsKey('评价')) {
          if (customFields.containsKey('健康度')) {
            customFields['评价'] = customFields.remove('健康度');
          } else if (customFields.containsKey('健康评价')) {
            customFields['评价'] = customFields.remove('健康评价');
          }
        }
      } else if (category == '活动') {
        if (!customFields.containsKey('type') &&
            !customFields.containsKey('类型')) {
          if (customFields.containsKey('活动类型')) {
            customFields['类型'] = customFields.remove('活动类型');
          } else if (customFields.containsKey('项目')) {
            customFields['类型'] = customFields.remove('项目');
          }
        }
      }

      final tagEntries = <TagEntry>[];
      if (customFields.isNotEmpty) {
        tagEntries.add(
          TagEntry(
            id: const Uuid().v4(),
            name: category,
            fields: customFields,
            time:
                '${recordTime.hour.toString().padLeft(2, '0')}:${recordTime.minute.toString().padLeft(2, '0')}',
          ),
        );
      }

      final recordTags = <String>[category];
      for (final t in explicitTags) {
        if (!recordTags.contains(t)) {
          recordTags.add(t);
        }
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
          tags: recordTags,
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
        tags: recordTags,
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
          WorkspaceEventBus.instance.emit(
            path,
            WorkspaceChangeType.deleted,
            oldRecord,
          );
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
          WorkspaceEventBus.instance.emit(
            path,
            WorkspaceChangeType.deleted,
            oldRecord,
          );
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
  Future<DiaryRecord?> _findTimelineRecord(
    DateTime date,
    DateTime recordTime,
    String title,
  ) async {
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

  Future<Map<String, dynamic>> _writeJournalFile(
    String path,
    String content,
  ) async {
    final dateStr = path
        .substring('/journal/'.length)
        .replaceAll('.md', '')
        .trim();
    DateTime date;
    try {
      date = DateTime.parse(dateStr);
    } catch (_) {
      date = DateTime.now();
    }
    await _journalService.saveJournal(date, content);
    WorkspaceEventBus.instance.emit(path, WorkspaceChangeType.updated, {
      'date': dateStr,
    });
    return {'status': 'saved', 'path': path, 'date': dateStr};
  }

  /// 写入小Q长期记忆文档：校验分类与容量上限，保存并广播事件。
  /// 容量超限直接抛错（对齐 Hermes 有界记忆），引导小Q先整合再写入
  Future<Map<String, dynamic>> _writeMemoryFile(
    String path,
    String content,
  ) async {
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
    WorkspaceEventBus.instance.emit(
      path,
      WorkspaceChangeType.updated,
      doc.toMap(),
    );
    return {
      'status': 'updated',
      'path': path,
      'usage': '${doc.usagePercent}%（${normalized.length}/$maxChars 字符）',
    };
  }

  /// 写入常用提示词列表：`/quick_prompts/prompts.md`
  ///
  /// 每行解析为一条提示词，以 "- " 开头的行自动剥离前缀；
  /// 空行自动跳过。全量覆写替换整个列表。
  Future<Map<String, dynamic>> _writeQuickPromptsFile(
    String path,
    String content,
  ) async {
    final name = path.substring('/quick_prompts/'.length).trim();
    if (name != 'prompts.md' && name.isNotEmpty) {
      throw Exception('未知的提示词文件: $path（仅支持 /quick_prompts/prompts.md）');
    }
    final prompts = content
        .split('\n')
        .map((line) => line.replaceFirst(RegExp(r'^-\s*'), '').trim())
        .where((line) => line.isNotEmpty)
        .toList();
    await QuickPromptService.instance.setPrompts(prompts);
    WorkspaceEventBus.instance.emit(
      '/quick_prompts/prompts.md',
      WorkspaceChangeType.updated,
      {'count': prompts.length},
    );
    return {
      'status': 'updated',
      'path': '/quick_prompts/prompts.md',
      'count': prompts.length,
    };
  }

  /// 写入用户自定义技能：`/skills/<名称>.md`（内置技能只读，直接拒绝）
  ///
  /// 正文为 Markdown 手册，frontmatter 的 `description` 作为技能索引描述；
  /// 缺失时回退取正文首个非空非标题行截断，避免索引里出现空描述。
  Future<Map<String, dynamic>> _writeSkillFile(
    String path,
    String content,
  ) async {
    final name = path.substring('/skills/'.length).trim();
    if (name.isEmpty || !name.endsWith('.md') || name.contains('/')) {
      throw Exception('非法的技能路径: $path（应为 /skills/<名称>.md，不支持子目录）');
    }
    final skillName = name.replaceAll(RegExp(r'\.md$'), '').trim();
    if (_skillRegistry.isBuiltinSkill(skillName)) {
      throw Exception(
        '「$skillName」是内置技能，不可修改。请用新的名称创建自定义技能，'
        '或直接创建同名以外的技能文件。',
      );
    }

    final parsed = _parseFrontmatter(content);
    final body = parsed.body.trim();
    if (body.isEmpty) {
      throw Exception('技能手册正文不能为空');
    }

    // frontmatter 未提供 description 时，从正文首个非标题行提取摘要；
    // 正文只有标题时退而取首个标题文本，避免索引里出现空描述
    var description = (parsed.meta['description'] as String? ?? '').trim();
    if (description.isEmpty) {
      final lines = body
          .split('\n')
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty)
          .toList();
      var fallback = lines.firstWhere(
        (l) => !l.startsWith('#'),
        orElse: () => lines.isEmpty
            ? ''
            : lines.first.replaceFirst(RegExp(r'^#+\s*'), ''),
      );
      if (fallback.length > 80) fallback = '${fallback.substring(0, 80)}…';
      description = fallback;
    }

    final existed = _skillRegistry.getUserSkill(skillName) != null;
    await _skillRegistry.saveUserSkill(
      AgentSkill(name: skillName, description: description, content: body),
    );
    WorkspaceEventBus.instance.emit(
      AgentSkill.pathOf(skillName),
      WorkspaceChangeType.updated,
      {'name': skillName},
    );
    return {
      'status': existed ? 'updated' : 'created',
      'path': AgentSkill.pathOf(skillName),
      'name': skillName,
      'description': description,
    };
  }

  Future<Map<String, dynamic>> _writeSettingsFile(
    String path,
    String content,
  ) async {
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
      WorkspaceEventBus.instance.emit(
        path,
        WorkspaceChangeType.updated,
        updatedData,
      );
      return {'status': 'updated', 'path': path, 'data': updatedData};
    }

    if (name == 'health.json') {
      if (decoded is! Map<String, dynamic>) {
        throw Exception('health.json 必须是 JSON 对象');
      }
      final prefs = await SharedPreferences.getInstance();
      if (decoded.containsKey('dailyStepTarget')) {
        final target = decoded['dailyStepTarget'];
        final parsed = target is num ? target.toInt() : int.tryParse('$target');
        if (parsed == null || parsed < 1000 || parsed > 100000) {
          throw Exception('dailyStepTarget 必须为 1000-100000 之间的整数步');
        }
        await prefs.setInt(HealthSyncService.keyDailyStepTarget, parsed);
      }
      if (decoded.containsKey('autoSync')) {
        if (decoded['autoSync'] is! bool) {
          throw Exception('autoSync 必须为布尔值 true/false');
        }
        await prefs.setBool(HealthSyncService.keyAutoSync, decoded['autoSync'] as bool);
      }
      final currentTarget = prefs.getInt(HealthSyncService.keyDailyStepTarget) ??
          HealthSyncService.defaultDailyStepTarget;
      final currentAutoSync = prefs.getBool(HealthSyncService.keyAutoSync) ?? true;
      final updatedData = {
        'dailyStepTarget': currentTarget,
        'autoSync': currentAutoSync,
      };
      WorkspaceEventBus.instance.emit(
        path,
        WorkspaceChangeType.updated,
        updatedData,
      );
      return {'status': 'updated', 'path': path, 'data': updatedData};
    }

    if (name == 'ai.json') {
      if (decoded is! Map<String, dynamic>) {
        throw Exception('ai.json 必须是 JSON 对象');
      }
      // 1. 更新 roles
      if (decoded.containsKey('roles') &&
          decoded['roles'] is Map<String, dynamic>) {
        final rolesMap = decoded['roles'] as Map<String, dynamic>;
        var currentRoles = await _configRepo.getAiRoles() ?? const AiRoles();
        if (rolesMap.containsKey('assistant') &&
            rolesMap['assistant'] is Map<String, dynamic>) {
          final ast = rolesMap['assistant'] as Map<String, dynamic>;
          currentRoles = currentRoles.copyWith(
            assistantUseFreeModel:
                ast['useFreeModel'] as bool? ??
                currentRoles.assistantUseFreeModel,
            assistantFreeModelId:
                ast['freeModelId'] as String? ??
                currentRoles.assistantFreeModelId,
            assistant: ast.containsKey('customModelId')
                ? ast['customModelId'] as String?
                : currentRoles.assistant,
          );
        }
        if (rolesMap.containsKey('timelineOptimization') &&
            rolesMap['timelineOptimization'] is Map<String, dynamic>) {
          final tlo = rolesMap['timelineOptimization'] as Map<String, dynamic>;
          currentRoles = currentRoles.copyWith(
            timelineOptimizationUseFreeModel:
                tlo['useFreeModel'] as bool? ??
                currentRoles.timelineOptimizationUseFreeModel,
            timelineOptimizationFreeModelId:
                tlo['freeModelId'] as String? ??
                currentRoles.timelineOptimizationFreeModelId,
            timelineOptimization: tlo.containsKey('customModelId')
                ? tlo['customModelId'] as String?
                : currentRoles.timelineOptimization,
          );
        }
        await _configRepo.saveAiRoles(currentRoles);
      }

      // 2. 更新 temperatures
      if (decoded.containsKey('temperatures') &&
          decoded['temperatures'] is Map<String, dynamic>) {
        final tempsMap = decoded['temperatures'] as Map<String, dynamic>;
        var currentTemps =
            await _configRepo.getAiTemperatures() ?? const AiTemperatures();
        if (tempsMap.containsKey('assistant') &&
            tempsMap['assistant'] is Map<String, dynamic>) {
          final ast = tempsMap['assistant'] as Map<String, dynamic>;
          currentTemps = currentTemps.copyWith(
            assistant: currentTemps.assistant.copyWith(
              temperature:
                  (ast['temperature'] as num?)?.toDouble() ??
                  currentTemps.assistant.temperature,
              maxTokens:
                  (ast['maxTokens'] as num?)?.toInt() ??
                  currentTemps.assistant.maxTokens,
            ),
          );
        }
        if (tempsMap.containsKey('timelineOptimization') &&
            tempsMap['timelineOptimization'] is Map<String, dynamic>) {
          final tlo = tempsMap['timelineOptimization'] as Map<String, dynamic>;
          currentTemps = currentTemps.copyWith(
            timelineOptimization: currentTemps.timelineOptimization.copyWith(
              temperature:
                  (tlo['temperature'] as num?)?.toDouble() ??
                  currentTemps.timelineOptimization.temperature,
              maxTokens:
                  (tlo['maxTokens'] as num?)?.toInt() ??
                  currentTemps.timelineOptimization.maxTokens,
              extractImages:
                  (tlo['extractImages'] as bool?) ??
                  currentTemps.timelineOptimization.extractImages,
            ),
          );
        }
        await _configRepo.saveAiTemperatures(currentTemps);
      }

      WorkspaceEventBus.instance.emit(
        path,
        WorkspaceChangeType.updated,
        decoded,
      );
      return {'status': 'updated', 'path': path};
    }

    if (name == 'personality.json') {
      if (decoded is! Map<String, dynamic>) {
        throw Exception('personality.json 必须是 JSON 对象');
      }
      await QPersonalityService.instance.applyPartialConfig(decoded);
      final updatedData = {
        'activeId': await QPersonalityService.instance.getActiveId(),
        'note': '个性已更新，下轮对话生效',
      };
      WorkspaceEventBus.instance.emit(
        path,
        WorkspaceChangeType.updated,
        updatedData,
      );
      return {'status': 'updated', 'path': path, 'data': updatedData};
    }

    if (name == 'shortcuts.json') {
      List<dynamic> list;
      if (decoded is List) {
        list = decoded;
      } else if (decoded is Map<String, dynamic> &&
          decoded['shortcuts'] is List) {
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
          sortOrder:
              (map['sort_order'] ?? map['sortOrder'] as num?)?.toInt() ?? i,
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
        final isTimePoint =
            map['is_time_point'] == 1 || map['isTimePoint'] == true;
        final content = map['content']?.toString();
        final isEnabled = map['is_enabled'] != 0 && map['isEnabled'] != false;
        final sortOrder =
            (map['sort_order'] ?? map['sortOrder'] as num?)?.toInt() ?? i;

        // 解析多时间段（兼顾标准 timePeriods、下划线 time_periods，以及模型自拟的 timeSlots / periods）
        List<TimePeriod> periods = [];
        dynamic rawPeriods =
            map['timePeriods'] ??
            map['time_periods'] ??
            map['timeSlots'] ??
            map['periods'];
        if (rawPeriods is String && rawPeriods.isNotEmpty) {
          try {
            rawPeriods = jsonDecode(rawPeriods);
          } catch (_) {}
        }
        if (rawPeriods is List) {
          for (final p in rawPeriods) {
            if (p is Map) {
              final s =
                  (p['startTime'] ?? p['start_time'] ?? p['start'] ?? '08:00')
                      .toString();
              final e = (p['endTime'] ?? p['end_time'] ?? p['end'] ?? '')
                  .toString();
              periods.add(
                TimePeriod(startTime: s, endTime: isTimePoint ? '' : e),
              );
            }
          }
        }

        // 如果没有提供多时段数组，则使用顶层的 start_time/startTime 与 end_time/endTime
        final fallbackStart = (map['start_time'] ?? map['startTime'] ?? '08:00')
            .toString();
        final fallbackEnd = (map['end_time'] ?? map['endTime'] ?? '')
            .toString();

        if (periods.isEmpty) {
          periods.add(
            TimePeriod(
              startTime: fallbackStart,
              endTime: isTimePoint ? '' : fallbackEnd,
            ),
          );
        }

        final startTime = periods.first.startTime;
        final endTime = isTimePoint ? '' : periods.first.endTime;

        List<String> tags = currentMap[id]?.tags ?? [];
        if (map['tags'] is List) {
          tags = (map['tags'] as List).map((e) => e.toString()).toList();
        } else if (map['tags'] is String &&
            (map['tags'] as String).isNotEmpty) {
          try {
            final decodedTags = jsonDecode(map['tags'] as String);
            if (decodedTags is List) {
              tags = decodedTags.map((e) => e.toString()).toList();
            }
          } catch (_) {}
        }

        final template = FixedEventTemplate(
          id: id,
          name: name,
          startTime: startTime,
          endTime: endTime,
          isTimePoint: isTimePoint,
          content: content,
          tags: tags,
          tagFields: currentMap[id]?.tagFields ?? {},
          sortOrder: sortOrder,
          isEnabled: isEnabled,
          timePeriods: periods,
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
      final profile =
          await _configRepo.getUserProfile() ??
          UserProfile(
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
      WorkspaceEventBus.instance.emit(
        '/settings/profile.json',
        WorkspaceChangeType.updated,
        updatedProfile,
      );
      WorkspaceEventBus.instance.emit(
        path,
        WorkspaceChangeType.updated,
        record,
      );
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
      if (mergedMap['weight_history'] != null &&
          mergedMap['weight_history'] is! String) {
        mergedMap['weight_history'] = jsonEncode(mergedMap['weight_history']);
      }
      if (mergedMap['custom_fields'] != null &&
          mergedMap['custom_fields'] is! String) {
        mergedMap['custom_fields'] = jsonEncode(mergedMap['custom_fields']);
      }

      mergedMap['id'] = existing?.id ?? const Uuid().v4();
      mergedMap['updated_at'] = DateTime.now().toIso8601String();
      if (!mergedMap.containsKey('created_at')) {
        mergedMap['created_at'] = DateTime.now().toIso8601String();
      }

      final profile = UserProfile.fromMap(mergedMap);
      await _configRepo.saveUserProfile(profile);
      WorkspaceEventBus.instance.emit(
        path,
        WorkspaceChangeType.updated,
        profile,
      );
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

        if (rawColor == null ||
            rawColor.isEmpty ||
            rawColor == 'none' ||
            rawColor == 'clear' ||
            rawColor == '清除') {
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
            hexColor =
                '#${c.toARGB32().toRadixString(16).padLeft(8, '0').toUpperCase()}';
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

      WorkspaceEventBus.instance.emit(
        '/settings/color_marks.json',
        WorkspaceChangeType.updated,
        {'count': processed},
      );
      WorkspaceEventBus.instance.emit(
        '/timeline/',
        WorkspaceChangeType.updated,
        {'count': processed},
      );
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
      WorkspaceEventBus.instance.emit(
        path,
        WorkspaceChangeType.updated,
        webdav,
      );
      return {'status': 'updated', 'path': path};
    }

    throw Exception('不支持修改此配置: $path');
  }

  Future<Map<String, dynamic>> _writeFoldersFile(
    String path,
    String content,
  ) async {
    final name = path.substring('/folders/'.length).trim();
    dynamic decoded;
    try {
      decoded = jsonDecode(content);
    } catch (e) {
      throw Exception('分类配置必须为合法 JSON 格式: $e');
    }

    final type = name == 'todos.json'
        ? 'todo'
        : (name == 'notes.json' ? 'note' : null);
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
      final parentId =
          map['parentId']?.toString() ?? map['parent_id']?.toString();
      final sortOrder =
          (map['sortOrder'] ?? map['sort_order'] as num?)?.toInt() ?? i;
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

    WorkspaceEventBus.instance.emit(path, WorkspaceChangeType.updated, {
      'type': type,
      'count': count,
    });
    return {'status': 'updated', 'path': path, 'type': type, 'count': count};
  }

  Future<Map<String, dynamic>> _writeChatsFile(
    String path,
    String content,
  ) async {
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
      final newTitle = item['title']?.toString().trim();
      if (id == null || id.isEmpty || newTitle == null || newTitle.isEmpty)
        continue;

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

    WorkspaceEventBus.instance.emit(
      '/chats/sessions.json',
      WorkspaceChangeType.updated,
      {'count': updatedCount},
    );
    return {'status': 'updated', 'path': path, 'updated_count': updatedCount};
  }

  /// 写入 /stats/ 下的评分数据
  Future<Map<String, dynamic>> _writeStatsFile(
    String path,
    String content,
  ) async {
    if (path == kStatsAdjustPath) {
      return await _writeStatsAdjustFile(content);
    }
    if (!path.startsWith('/stats/scores/')) {
      throw Exception(
        '当前统计路径不支持直接覆写: $path（宏观汇总 summary.json / daily_scores.json 仅供读取，若要给某天评分或修改分数，请写入单日路径: /stats/scores/YYYY-MM-DD.json）',
      );
    }

    final dateStr = path
        .substring('/stats/scores/'.length)
        .replaceAll('.json', '')
        .trim();
    DateTime date;
    try {
      date = DateTime.parse(dateStr);
    } catch (_) {
      throw Exception('无效的评分日期格式: $dateStr（正确格式应为 YYYY-MM-DD.json）');
    }

    dynamic decoded;
    try {
      decoded = jsonDecode(content);
    } catch (e) {
      throw Exception('评分数据必须是合法的 JSON 格式: $e');
    }

    if (decoded is! Map<String, dynamic>) {
      throw Exception('评分数据必须是 JSON 对象');
    }

    // 未出现的字段一律不改：缺省的总分不再兜成 60，缺失的维度不再被总分覆盖
    final rawTotal =
        decoded['totalScore'] ?? decoded['total_score'] ?? decoded['score'];
    final int? totalScore = rawTotal is num ? rawTotal.toInt() : null;

    final rawDims =
        decoded['dimensionScores'] ??
        decoded['dimension_scores'] ??
        decoded['dimensions'];
    final Map<String, int> dimensionScores = {};
    if (rawDims is Map) {
      for (final entry in rawDims.entries) {
        final key = entry.key.toString().trim();
        final val = entry.value;
        if (val is num) {
          dimensionScores[key] = val.toInt();
        }
      }
    }

    // 总结与建议
    final summary = (decoded['summary'] ?? '').toString().trim();
    final suggestions = (decoded['suggestions'] ?? decoded['suggestion'] ?? '')
        .toString()
        .trim();

    // 记录数量：payload 未给时按当天流水数；0 视为未提供，保留库里原值
    int? recordCount;
    final rawCount = decoded['recordCount'] ?? decoded['record_count'];
    if (rawCount is num) {
      recordCount = rawCount.toInt();
    } else {
      final records = await _diaryRepo.getByDate(date);
      if (records.isNotEmpty) recordCount = records.length;
    }

    final result = await DailyScoreService.instance.upsertFromPayload(
      date: date,
      totalScore: totalScore,
      dimensionScores: dimensionScores,
      summary: summary,
      suggestions: suggestions,
      recordCount: recordCount,
    );

    // 回显刻意不含 summary：批量改分时逐日评语原文会白白吃掉大量上下文
    return {
      'status': result.status,
      'path': path,
      'id': result.saved.id,
      'date': dateStr,
      'totalScore': result.saved.totalScore,
      'dimensionScores': result.saved.dimensionScores,
    };
  }

  /// 范围批量调整历史评分：一次调用改完一段日期区间。
  ///
  /// 为什么不逐天 write_file：那等于把上百个整数加减交给模型心算，算错了既不
  /// 报错也看不出来；加减分统一由 [applyScoreAdjust] 计算并钳位。
  Future<Map<String, dynamic>> _writeStatsAdjustFile(String content) async {
    dynamic decoded;
    try {
      decoded = jsonDecode(content);
    } catch (e) {
      throw Exception('评分调整指令必须是合法的 JSON 格式: $e');
    }
    if (decoded is! Map<String, dynamic>) {
      throw Exception('评分调整指令必须是 JSON 对象');
    }

    final from = _parseStatsDate(
      decoded['dateFrom'] ?? decoded['from'] ?? decoded['start'],
      'dateFrom',
    );
    final to = _parseStatsDate(
      decoded['dateTo'] ?? decoded['to'] ?? decoded['end'],
      'dateTo',
    );
    final fields = _parseScoreFields(decoded['fields']);

    final rawDelta = decoded['delta'] ?? decoded['offset'];
    final rawSet = decoded['setValue'] ?? decoded['set'];
    if ((rawDelta is num) == (rawSet is num)) {
      throw Exception('delta（加减分）与 setValue（设为固定值）必须且只能提供一个');
    }
    final spec = rawDelta is num
        ? ScoreAdjustSpec(delta: rawDelta.toInt(), fields: fields)
        : ScoreAdjustSpec(setValue: (rawSet as num).toInt(), fields: fields);
    final dryRun = decoded['dryRun'] == true;

    final service = DailyScoreService.instance;
    if (!dryRun) {
      // 先算一遍拿到「实际会变更的日期」，逐天补捕撤回快照
      final preview = await service.adjustRange(
        from: from,
        to: to,
        spec: spec,
        dryRun: true,
      );
      for (final outcome in preview.outcomes) {
        await _captureUndoState(
          '/stats/scores/${_statsDateKey(outcome.before.date)}.json',
        );
      }
    }

    final adjusted = await service.adjustRange(
      from: from,
      to: to,
      spec: spec,
      dryRun: dryRun,
    );
    return {
      'status': dryRun ? 'preview' : 'adjusted',
      'range': '${_statsDateKey(from)} ~ ${_statsDateKey(to)}',
      'applied': adjusted.applied,
      'scoredDays': adjusted.scoredDays,
      'missingDays': adjusted.missingDays,
      'clampedDays': adjusted.clamped,
      'summary': adjusted.preview,
      'changes': adjusted.outcomes
          .take(8)
          .map(
            (o) => {
              'date': _statsDateKey(o.before.date),
              'fields': o.changes
                  .map((c) => '${c.field.label} ${c.before ?? '—'}→${c.after}')
                  .toList(),
            },
          )
          .toList(),
    };
  }

  /// 评分端点里的日期归一化为 `YYYY-MM-DD`
  String _statsDateKey(DateTime date) => date.toIso8601String().split('T').first;

  DateTime _parseStatsDate(dynamic raw, String label) {
    final text = (raw ?? '').toString().trim();
    if (text.isEmpty) {
      throw Exception('缺少 $label（格式 YYYY-MM-DD）');
    }
    try {
      final parsed = DateTime.parse(text);
      return DateTime(parsed.year, parsed.month, parsed.day);
    } catch (_) {
      throw Exception('$label 日期格式无效: $text（应为 YYYY-MM-DD）');
    }
  }

  Set<ScoreField> _parseScoreFields(dynamic raw) {
    if (raw is! List || raw.isEmpty) return kAllScoreFields;
    final fields = <ScoreField>{};
    for (final entry in raw) {
      final field = ScoreField.fromKey(entry.toString());
      if (field == null) {
        throw Exception('未知的评分字段: $entry（可选 total/sleep/diet/activity/health/screen）');
      }
      fields.add(field);
    }
    return fields;
  }

  /// 颜色解析辅助方法（支持 hex #RRGGBB、#AARRGGBB 与常见颜色别名）
  Color? _parseColor(dynamic raw) {
    if (raw == null) return null;
    if (raw is int) return Color(raw);
    if (raw is String) {
      final s = raw.trim().toLowerCase();
      if (s == 'classic_blue' || s == 'blue' || s == '经典蓝')
        return const Color(0xFF005BCB);
      if (s == 'yellow_green' || s == '荧光黄绿') return const Color(0xFFC5E803);
      if (s == 'pink' || s == 'rose' || s == '玫瑰粉红')
        return const Color(0xFFE91E8C);
      if (s == 'green' || s == '春天亮绿') return const Color(0xFF00E676);
      if (s == 'red' || s == '红色' || s == '活力红') return const Color(0xFFFF3B30);
      if (s == 'orange' || s == '橙色' || s == '活力橙') return const Color(0xFFFF9500);
      if (s == 'cyan' || s == '青色' || s == '湖水青') return const Color(0xFF00BCD4);
      if (s == 'purple' || s == '紫色' || s == '典雅紫') return const Color(0xFF7C4DFF);
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
    if (s == 'dark' || s == '深色' || s == '暗色' || s == '夜间' || s == '黑')
      return ThemeMode.dark;
    if (s == 'light' || s == '浅色' || s == '明亮' || s == '日间' || s == '白')
      return ThemeMode.light;
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
    // 去掉行号前缀：锚定"行首数字+制表符"，避免误伤正文中含制表符的内容
    final originalContent = stripLineNumbers(await readFile(path));
    // 模型常把 read_file 回显里的行号连同正文一起复制进 old_text/new_text，
    // 这里对参数做同样的剥离，否则「肉眼看完全一致」的文本也会匹配失败
    final target = stripLineNumbers(oldText);
    final replacement = stripLineNumbers(newText);

    if (!originalContent.contains(target)) {
      throw Exception(
        '在文件 $path 中未找到要替换的文本。请先 read_file 核对原文，'
        'old_text 应为文件正文原样片段（不要带行号前缀，也不要照抄整段回显）：\n$oldText',
      );
    }

    final newContent = replaceAll
        ? originalContent.replaceAll(target, replacement)
        : originalContent.replaceFirst(target, replacement);

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
        final folderName = path
            .substring('/todos/'.length)
            .replaceAll('/', '')
            .trim();
        final folders = await _folderRepo.getByType('todo');
        final matched = folders
            .where((f) => f.name == folderName || f.id == folderName)
            .firstOrNull;
        if (matched != null) {
          if (matched.id == 'todo_default_today' ||
              matched.id == 'todo_default_longterm') {
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
          WorkspaceEventBus.instance.emit(
            path,
            WorkspaceChangeType.deleted,
            matched,
          );
          WorkspaceEventBus.instance.emit(
            '/folders/todos.json',
            WorkspaceChangeType.updated,
            matched,
          );
          return {
            'status': 'deleted',
            'path': path,
            'folder': matched.name,
            'todos_deleted': deletedCount,
          };
        }
      }

      // 2. 单个待办文件删除
      final segments = path.substring('/todos/'.length).split('/');
      final rawTitle = segments.last
          .replaceAll('.md', '')
          .replaceAll(RegExp(r'^\[[ x]\]\s*'), '')
          .trim();
      final allTodos = await _todoRepo.getAll();
      final matched = allTodos
          .where((t) => t.id == rawTitle || t.title.trim() == rawTitle)
          .firstOrNull;
      if (matched != null) {
        await _todoRepo.softDelete(matched.id);
        WorkspaceEventBus.instance.emit(
          path,
          WorkspaceChangeType.deleted,
          matched,
        );
        return {
          'status': 'deleted',
          'path': path,
          'id': matched.id,
          'title': matched.title,
        };
      }
      throw Exception('未找到要删除的待办: $path');
    }

    if (path.startsWith('/notes/')) {
      // 1. 如果路径是笔记本分类目录（以 '/' 结尾或没有 .md 后缀）
      if (!path.endsWith('.md')) {
        final folderName = path
            .substring('/notes/'.length)
            .replaceAll('/', '')
            .trim();
        final folders = await _folderRepo.getByType('note');
        final matched = folders
            .where((f) => f.name == folderName || f.id == folderName)
            .firstOrNull;
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
          WorkspaceEventBus.instance.emit(
            path,
            WorkspaceChangeType.deleted,
            matched,
          );
          WorkspaceEventBus.instance.emit(
            '/folders/notes.json',
            WorkspaceChangeType.updated,
            matched,
          );
          return {
            'status': 'deleted',
            'path': path,
            'folder': matched.name,
            'notes_deleted': deletedCount,
          };
        }
      }

      // 2. 单个笔记文件删除
      final segments = path.substring('/notes/'.length).split('/');
      final rawTitle = segments.last.replaceAll('.md', '').trim();
      final allNotes = await _noteRepo.getAll();
      final matched = allNotes
          .where((n) => n.id == rawTitle || n.title.trim() == rawTitle)
          .firstOrNull;
      if (matched != null) {
        await _noteRepo.softDelete(matched.id);
        WorkspaceEventBus.instance.emit(
          path,
          WorkspaceChangeType.deleted,
          matched,
        );
        return {
          'status': 'deleted',
          'path': path,
          'id': matched.id,
          'title': matched.title,
        };
      }
      throw Exception('未找到要删除的笔记: $path');
    }

    if (path.startsWith('/journal/')) {
      final dateStr = path
          .substring('/journal/'.length)
          .replaceAll('.md', '')
          .trim();
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
      WorkspaceEventBus.instance.emit(path, WorkspaceChangeType.deleted, {
        'date': dateStr,
        'id': existing.id,
      });
      return {
        'status': 'deleted',
        'path': path,
        'id': existing.id,
        'title': '$dateStr 日记',
      };
    }

    if (path.startsWith('/timeline/')) {
      final subPath = path
          .substring('/timeline/'.length)
          .replaceAll('.md', '')
          .trim();
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
        WorkspaceEventBus.instance.emit(path, WorkspaceChangeType.deleted, {
          'date': subPath,
          'count': records.length,
        });
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
          WorkspaceEventBus.instance.emit(
            path,
            WorkspaceChangeType.deleted,
            record,
          );
          return {
            'status': 'deleted',
            'path': path,
            'id': record.id,
            'title': record.title,
            'time': record.time.toIso8601String(),
          };
        }
      }

      throw Exception(
        '未找到对应的时间线记录或无效的日期路径: $path (必须为 /timeline/YYYY-MM-DD.md 或 /timeline/<id>.md)',
      );
    }

    if (path.startsWith('/memory/')) {
      final category = AgentMemoryCategory.fromPath(path);
      if (category == null) {
        throw Exception(
          '未知的记忆文件: $path（仅支持 /memory/user.md 与 /memory/agent.md）',
        );
      }
      // 删除记忆文档 = 清空全部条目（保留分类本身，可随时重新写入）
      await _configRepo.saveAgentMemory(
        AgentMemoryDocument(category: category, content: ''),
      );
      WorkspaceEventBus.instance.emit(path, WorkspaceChangeType.deleted, {
        'category': category,
      });
      return {
        'status': 'deleted',
        'path': path,
        'title': '${AgentMemoryCategory.displayName(category)}已清空',
      };
    }

    if (path.startsWith('/quick_prompts/')) {
      // 删除 = 清空全部提示词（列表本身可随时重新写入）
      await QuickPromptService.instance.setPrompts([]);
      WorkspaceEventBus.instance.emit(
        '/quick_prompts/prompts.md',
        WorkspaceChangeType.deleted,
        {'cleared': true},
      );
      return {'status': 'deleted', 'path': path, 'title': '常用提示词已清空'};
    }

    if (path.startsWith('/skills/')) {
      final name = path
          .substring('/skills/'.length)
          .trim()
          .replaceAll(RegExp(r'\.md$'), '')
          .trim();
      if (name.isEmpty || name.contains('/')) {
        throw Exception('非法的技能路径: $path（应为 /skills/<名称>.md）');
      }
      if (_skillRegistry.isBuiltinSkill(name)) {
        throw Exception('「$name」是内置技能，不可删除');
      }
      if (_skillRegistry.getUserSkill(name) == null) {
        throw Exception('未找到技能: $name（内置技能与已有自定义技能请查看 /skills/）');
      }
      await _skillRegistry.deleteUserSkill(name);
      WorkspaceEventBus.instance.emit(
        AgentSkill.pathOf(name),
        WorkspaceChangeType.deleted,
        {'name': name},
      );
      return {'status': 'deleted', 'path': path, 'name': name};
    }

    if (path.startsWith('/chats/')) {
      final segments = path.substring('/chats/'.length).split('/');
      final id = segments.last.replaceAll('.json', '').trim();
      if (id.isNotEmpty) {
        // 物理删除：软删只打标记、不释放空间，且会让已删会话在多端被快照回灌复活。
        // 删除范围仅限这条会话自身（消息 + 它独占的生成图），不会级联笔记/日记/待办。
        await _configRepo.hardDeleteChatSession(id);
        WorkspaceEventBus.instance.emit(
          '/chats/sessions.json',
          WorkspaceChangeType.deleted,
          {'id': id},
        );
        return {'status': 'deleted', 'path': path, 'id': id};
      }
      throw Exception('未指定要删除的会话 ID: $path (例如: /chats/<session_id>.json)');
    }

    if (path.startsWith('/stats/scores/')) {
      final dateStr = path
          .substring('/stats/scores/'.length)
          .replaceAll('.json', '')
          .trim();
      DateTime date;
      try {
        date = DateTime.parse(dateStr);
      } catch (_) {
        throw Exception('无效的评分日期格式: $dateStr（正确格式应为 YYYY-MM-DD.json）');
      }
      final existing = await _dailyScoreRepo.getByDate(date);
      if (existing != null) {
        await _dailyScoreRepo.delete(existing.id);
        WorkspaceEventBus.instance.emit(path, WorkspaceChangeType.deleted, {
          'id': existing.id,
          'date': dateStr,
        });
        WorkspaceEventBus.instance.emit(
          '/stats/daily_scores.json',
          WorkspaceChangeType.updated,
          {'id': existing.id, 'date': dateStr},
        );
        return {
          'status': 'deleted',
          'path': path,
          'id': existing.id,
          'date': dateStr,
        };
      }
      return {'status': 'noop', 'path': path, 'message': '未找到该日期的评分记录，无需删除'};
    }

    throw Exception('当前路径不支持直接删除: $path');
  }

  // ==========================================
  // 5.1 moveFile: 移动/改名（待办改分类、笔记换笔记本或重命名）
  // ==========================================
  /// 把待办或笔记移动到新路径：目标路径的目录段决定新归属，末段决定新标题
  ///
  /// 替代「read → write → delete」三步写法——那三步会消耗三轮工具调用，且中间任一步
  /// 失败都会留下重复条目；本方法在一次调用内完成归属与标题变更。
  /// 目标路径写成 `/notes/<标题>.md`（无笔记本段）表示移出笔记本到根目录。
  Future<Map<String, dynamic>> moveFile(String rawFrom, String rawTo) async {
    final from = normalizePath(rawFrom);
    final to = normalizePath(rawTo);
    if (from == to) {
      throw Exception('源路径与目标路径相同，无需移动: $from');
    }

    if (from.startsWith('/todos/') && to.startsWith('/todos/')) {
      return _moveTodo(from, to);
    }
    if (from.startsWith('/notes/') && to.startsWith('/notes/')) {
      return _moveNote(from, to);
    }
    throw Exception('暂不支持移动该路径: $from → $to（仅支持待办与笔记的移动/改名）');
  }

  Future<Map<String, dynamic>> _moveTodo(String from, String to) async {
    final sourceKey = _entityKeyFromPath(from, '/todos/');
    final allTodos = await _todoRepo.getAll();
    final existing =
        allTodos.where((t) => t.id == sourceKey).firstOrNull ??
        allTodos.where((t) => t.title.trim() == sourceKey).firstOrNull;
    if (existing == null) {
      throw Exception('未找到要移动的待办: $from');
    }

    final segments = to.substring('/todos/'.length).split('/');
    final hasFolder = segments.length >= 2;
    final folderName = hasFolder ? segments.first.trim() : '今日';
    final targetTitle = _stripTodoTitlePrefix(
      (hasFolder ? segments.sublist(1).join('/') : segments.first).replaceAll(
        '.md',
        '',
      ),
    );
    if (targetTitle.isEmpty) {
      throw Exception('目标待办标题不能为空: $to');
    }

    // 撤回录制：源路径（移动前状态）与目标路径（可能覆盖同名文件）都要留快照
    await _captureUndoState(from);
    await _captureUndoState(to);

    final isLongTerm = folderName == '长期';
    final folderId = await _resolveTodoFolder(
      folderName,
      isLongTerm: isLongTerm,
    );
    final updated = existing.copyWith(
      title: targetTitle,
      folderId: folderId,
      isLongTerm: isLongTerm,
      updatedAt: DateTime.now(),
    );
    await _todoRepo.update(updated);
    await NotificationService.instance.scheduleTodoReminder(updated);
    WorkspaceEventBus.instance.emit(
      from,
      WorkspaceChangeType.deleted,
      existing,
    );
    WorkspaceEventBus.instance.emit(to, WorkspaceChangeType.created, updated);
    return {
      'status': 'moved',
      'from': from,
      'path': to,
      'id': updated.id,
      'title': updated.title,
      'folder': folderName,
      'folder_id': folderId,
    };
  }

  Future<Map<String, dynamic>> _moveNote(String from, String to) async {
    final sourceKey = _entityKeyFromPath(from, '/notes/');
    final allNotes = await _noteRepo.getAll();
    final existing =
        allNotes.where((n) => n.id == sourceKey).firstOrNull ??
        allNotes.where((n) => n.title.trim() == sourceKey).firstOrNull;
    if (existing == null) {
      throw Exception('未找到要移动的笔记: $from');
    }
    // 日记按日期自动归档（id 前缀 journal_note_），改名会破坏日期检索
    if (JournalService.isJournalNote(existing.id)) {
      throw Exception('每日日记不支持移动或改名: $from（按日期自动归档，请直接编辑正文）');
    }

    final segments = to.substring('/notes/'.length).split('/');
    final hasFolder = segments.length >= 2;
    final targetTitle =
        (hasFolder ? segments.sublist(1).join('/') : segments.first)
            .replaceAll('.md', '')
            .trim();
    if (targetTitle.isEmpty) {
      throw Exception('目标笔记标题不能为空: $to');
    }

    await _captureUndoState(from);
    await _captureUndoState(to);

    // 目标路径带笔记本段则移入该笔记本（不存在会自动创建）；不带则移出到根目录
    final String? folderId = hasFolder
        ? await _resolveOrCreateNoteFolder(segments.first.trim())
        : null;
    final updated = existing.copyWith(
      title: targetTitle,
      folderId: folderId,
      updatedAt: DateTime.now(),
    );
    await _noteRepo.update(updated);
    WorkspaceEventBus.instance.emit(
      from,
      WorkspaceChangeType.deleted,
      existing,
    );
    WorkspaceEventBus.instance.emit(to, WorkspaceChangeType.created, updated);
    return {
      'status': 'moved',
      'from': from,
      'path': to,
      'id': updated.id,
      'title': updated.title,
    };
  }

  /// 取路径末段的实体标识（标题或 id），去掉 .md 后缀与待办勾选前缀
  static String _entityKeyFromPath(String path, String prefix) {
    final rest = path.substring(prefix.length);
    return _stripTodoTitlePrefix(rest.split('/').last.replaceAll('.md', ''));
  }

  /// 去掉待办标题的勾选前缀（`[ ] ` / `[x] `）
  static String _stripTodoTitlePrefix(String title) =>
      title.replaceAll(RegExp(r'^\[[ x]\]\s*'), '').trim();

  // ==========================================
  // 6. grep: 全局检索（VFS 唯一检索实现，GrepTool 直接复用）
  // ==========================================
  /// 支持的检索范围；`all` 表示全库
  static const List<String> grepScopes = [
    'all',
    'notes',
    'todos',
    'timeline',
    'journal',
    'memory',
    'settings',
    'chats',
    'stats',
  ];

  /// 单条命中文本（match）的最大长度，控制回传给模型的体积
  static const int _grepMatchMaxLength = 200;

  /// 全库关键词/正则检索，返回**带可操作虚拟路径**的命中列表
  ///
  /// 关键设计：每条命中都必须携带 `path`，而不是只有数据库 id。
  /// 写入口按「导入路径末段 = 标题」匹配既有实体，模型若把裸 id 当路径去
  /// write_file，会匹配不到实体而新建一条 UUID 标题的脏记录；因此这里统一回传
  /// canonical 路径（read/write/edit/delete 四条链路都能解析的形态），
  /// 让模型可以「检索 → 直接改写」闭环，无需二次试探。
  Future<List<Map<String, dynamic>>> grep(
    String query, {
    String scope = 'all',
    int maxResults = 20,
  }) async {
    final results = <Map<String, dynamic>>[];
    final keyword = query.trim();
    if (keyword.isEmpty) return results;

    final reg = _buildGrepRegExp(keyword);
    final limit = maxResults.clamp(1, 200);
    bool inScope(String name) => scope == 'all' || scope == name;

    // 1. 待办（/todos/<分类>/<标题>.md）
    if (inScope('todos')) {
      final todos = await _todoRepo.getAll();
      final folders = await _folderRepo.getByType('todo');
      final folderMap = {for (final f in folders) f.id: f.name};
      for (final t in todos) {
        if (results.length >= limit) break;
        if (!reg.hasMatch(t.title) && !reg.hasMatch(t.description)) continue;
        final folderName =
            folderMap[t.folderId] ?? (t.isLongTerm ? '长期' : '今日');
        final title = t.title.trim().isEmpty ? '未命名待办' : t.title.trim();
        results.add({
          'type': 'todo',
          'path': '/todos/$folderName/$title.md',
          'id': t.id,
          'title': title,
          'is_completed': t.isCompleted,
          'snippet': _grepSnippet(
            t.description.trim().isEmpty ? t.title : t.description,
            reg,
          ),
        });
      }
    }

    // 2. 笔记（/notes/<笔记本>/<标题>.md）与每日日记（/journal/YYYY-MM-DD.md）
    //    日记复用 notes 表存储（id 前缀 journal_note_），需按范围分流，避免日记被误标为笔记
    if (inScope('notes') || inScope('journal')) {
      final notes = await _noteRepo.getAll();
      final noteFolders = await _folderRepo.getByType('note');
      final noteFolderMap = {for (final f in noteFolders) f.id: f.name};
      for (final n in notes) {
        if (results.length >= limit) break;
        final isJournal = JournalService.isJournalNote(n.id);
        if (isJournal && !inScope('journal')) continue;
        if (!isJournal && !inScope('notes')) continue;
        if (!reg.hasMatch(n.title) && !reg.hasMatch(n.content)) continue;
        if (isJournal) {
          results.add({
            'type': 'journal',
            'path': '/journal/${n.title.trim()}.md',
            'id': n.id,
            'title': n.title,
            'snippet': _grepSnippet(n.content, reg),
          });
          continue;
        }
        final folderName = noteFolderMap[n.folderId];
        final title = n.title.trim().isEmpty ? '未命名笔记' : n.title.trim();
        final path = (folderName == null || folderName.isEmpty)
            ? '/notes/$title.md'
            : '/notes/$folderName/$title.md';
        results.add({
          'type': 'note',
          'path': path,
          'id': n.id,
          'title': title,
          'snippet': _grepSnippet(n.content, reg),
        });
      }
    }

    // 3. 时间线流水（按天文件，单条事件用返回的 id 精确删除）
    if (inScope('timeline')) {
      final records = await _diaryRepo.getAll();
      for (final r in records) {
        if (results.length >= limit) break;
        if (!reg.hasMatch(r.title) &&
            !reg.hasMatch(r.content) &&
            !reg.hasMatch(r.displayTag)) {
          continue;
        }
        final dateStr = _formatDate(r.time);
        final timeStr =
            '${r.time.hour.toString().padLeft(2, '0')}:'
            '${r.time.minute.toString().padLeft(2, '0')}';
        results.add({
          'type': 'timeline',
          'path': '/timeline/$dateStr.md',
          'id': r.id,
          'title': r.title,
          'time': r.time.toIso8601String(),
          'tags': r.tags,
          'match': '[$timeStr] ${r.displayTag} - ${r.title}',
          'snippet': _grepSnippet(r.content, reg),
        });
      }
    }

    // 4. 长期记忆（/memory/user.md、/memory/agent.md）
    if (inScope('memory')) {
      for (final path in const ['/memory/user.md', '/memory/agent.md']) {
        if (results.length >= limit) break;
        await _collectLineHits(
          path: path,
          content: await _readMemoryFile(path),
          reg: reg,
          type: 'memory',
          out: results,
          limit: limit,
        );
      }
    }

    // 5. 系统配置（/settings/*.json）
    if (inScope('settings')) {
      for (final file in _settingsFileNames) {
        if (results.length >= limit) break;
        final path = '/settings/$file';
        await _collectLineHits(
          path: path,
          content: await _readSettingsFile(path),
          reg: reg,
          type: 'settings',
          out: results,
          limit: limit,
        );
      }
    }

    // 6. 历史会话（/chats/sessions.json）
    if (inScope('chats')) {
      await _collectLineHits(
        path: '/chats/sessions.json',
        content: await _readChatsFile('/chats/sessions.json'),
        reg: reg,
        type: 'chats',
        out: results,
        limit: limit,
      );
    }

    // 7. 统计评分（/stats/scores/YYYY-MM-DD.json 及 /stats/daily_scores.json）
    if (inScope('stats')) {
      final now = DateTime.now();
      final startDate = DateTime(
        now.year,
        now.month,
        now.day,
      ).subtract(const Duration(days: 30));
      final scores = await _dailyScoreRepo.getByDateRange(startDate, now);
      for (final s in scores) {
        if (results.length >= limit) break;
        final dateStr = s.date.toIso8601String().substring(0, 10);
        final fullText =
            '${s.summary} ${s.suggestions} 总分:${s.totalScore} 维度:${s.dimensionScores}';
        if (!reg.hasMatch(fullText) && !reg.hasMatch(dateStr)) continue;
        results.add({
          'type': 'stats',
          'path': '/stats/scores/$dateStr.json',
          'id': s.id,
          'date': dateStr,
          'totalScore': s.totalScore,
          'match': '[$dateStr] 生活评分 ${s.totalScore}分: ${s.summary}',
          'snippet': _grepSnippet(
            s.summary.isNotEmpty ? s.summary : s.suggestions,
            reg,
          ),
        });
      }
    }

    return results;
  }

  /// 构造检索正则：非法正则自动降级为按字面量匹配，避免模型传入的表达式直接抛错
  RegExp _buildGrepRegExp(String query) {
    try {
      return RegExp(query, caseSensitive: false);
    } catch (_) {
      return RegExp(RegExp.escape(query), caseSensitive: false);
    }
  }

  /// 为整篇内容类命中生成上下文摘要（命中点前后各取一段）
  String _grepSnippet(String content, RegExp reg) {
    final text = content.trim();
    if (text.isEmpty) return '';
    final match = reg.firstMatch(text);
    if (match == null) {
      return text.length > _grepMatchMaxLength
          ? '${text.substring(0, _grepMatchMaxLength)}…'
          : text;
    }
    final start = (match.start - 30).clamp(0, text.length);
    final end = (match.end + 50).clamp(0, text.length);
    var snippet = text.substring(start, end).replaceAll('\n', ' ').trim();
    if (start > 0) snippet = '…$snippet';
    if (end < text.length) snippet = '$snippet…';
    return snippet.length > _grepMatchMaxLength
        ? '${snippet.substring(0, _grepMatchMaxLength)}…'
        : snippet;
  }

  /// 逐行收集命中（记忆/配置/会话等结构简单、整篇读取成本低的端点）
  ///
  /// 附带 `line` 行号，模型可据此用 read_file(path, offset) 精确定位上下文
  Future<void> _collectLineHits({
    required String path,
    required String content,
    required RegExp reg,
    required String type,
    required List<Map<String, dynamic>> out,
    required int limit,
  }) async {
    final lines = content.split('\n');
    for (var i = 0; i < lines.length; i++) {
      if (out.length >= limit) return;
      final line = lines[i].trim();
      if (line.isEmpty || !reg.hasMatch(line)) continue;
      out.add({
        'type': type,
        'path': path,
        'line': i + 1,
        'match': line.length > _grepMatchMaxLength
            ? '${line.substring(0, _grepMatchMaxLength)}…'
            : line,
      });
    }
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
