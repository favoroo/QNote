import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:qnote_flutter/config/defaults.dart';
import 'package:qnote_flutter/core/ai/ai_error_explainer.dart';
import 'package:qnote_flutter/core/ai/ai_service.dart';
import 'package:qnote_flutter/core/ai/ai_role_service.dart';
import 'package:qnote_flutter/core/ai/free_model_service.dart';
import 'package:qnote_flutter/core/logger/logger_service.dart';
import 'package:qnote_flutter/core/agent/agent_tool_labels.dart';
import 'package:qnote_flutter/core/agent/agent_tool_registry.dart';
import 'package:qnote_flutter/core/agent/engine/agent_cancellation_token.dart';
import 'package:qnote_flutter/core/agent/engine/agent_events.dart';
import 'package:qnote_flutter/core/agent/engine/agent_loop.dart';
import 'package:qnote_flutter/core/agent/prompts/q_system_prompt.dart';
import 'package:qnote_flutter/core/agent/services/agent_tool_config.dart';
import 'package:qnote_flutter/core/agent/services/q_personality_service.dart';
import 'package:qnote_flutter/core/agent/skills/skill_registry.dart';
import 'package:qnote_flutter/core/agent/skills/skill_usage_tracker.dart';
import 'package:qnote_flutter/core/agent/vfs/virtual_workspace_service.dart';
import 'package:qnote_flutter/core/agent/vfs/workspace_event_bus.dart';
import 'package:qnote_flutter/core/agent/vfs/workspace_undo_entry.dart';
import 'package:qnote_flutter/core/storage/config_repository.dart';
import 'package:qnote_flutter/core/storage/journal_service.dart';
import 'package:qnote_flutter/core/storage/note_repository.dart';
import 'package:qnote_flutter/core/storage/todo_repository.dart';
import 'package:qnote_flutter/providers/agent_support.dart';
import 'package:qnote_flutter/models/ai_config.dart';
import 'package:qnote_flutter/models/ai_roles.dart';
import 'package:qnote_flutter/models/chat_session.dart';
import 'package:qnote_flutter/models/free_model_config.dart';
import 'package:qnote_flutter/models/note.dart';
import 'package:qnote_flutter/models/todo.dart';
import 'package:uuid/uuid.dart';

final aiServiceProvider = Provider<AiService>((ref) {
  return AiService();
});

final aiRolesProvider = FutureProvider<AiRoles?>((ref) async {
  void onWorkspaceChange(WorkspaceChangeEvent event) {
    if (event.path == '/settings/ai.json') {
      ref.invalidateSelf();
    }
  }

  WorkspaceEventBus.instance.addListener(onWorkspaceChange);
  ref.onDispose(() {
    WorkspaceEventBus.instance.removeListener(onWorkspaceChange);
  });
  final repo = ConfigRepository.instance;
  return repo.getAiRoles();
});

final aiTemperaturesProvider = FutureProvider<AiTemperatures?>((ref) async {
  void onWorkspaceChange(WorkspaceChangeEvent event) {
    if (event.path == '/settings/ai.json') {
      ref.invalidateSelf();
    }
  }

  WorkspaceEventBus.instance.addListener(onWorkspaceChange);
  ref.onDispose(() {
    WorkspaceEventBus.instance.removeListener(onWorkspaceChange);
  });
  final repo = ConfigRepository.instance;
  return repo.getAiTemperatures();
});

// 免费模型相关 Provider
final freeModelsProvider =
    FutureProvider<List<FreeModelConfig>>((ref) async {
  return FreeModelService.instance.getCachedModels();
});

final freeModelsManifestProvider =
    FutureProvider<FreeModelsManifest?>((ref) async {
  return FreeModelService.instance.getCachedManifest();
});

final freeModelsLastUpdateProvider = FutureProvider<DateTime?>((ref) async {
  return FreeModelService.instance.getLastUpdateTime();
});

// 用户选择的主模型ID
final selectedFreeModelProvider = StateProvider<String?>((ref) => null);

// 免费模型更新状态
final freeModelUpdatingProvider = StateProvider<bool>((ref) => false);

final aiConfigListProvider =
    AsyncNotifierProvider<AiConfigListNotifier, List<AiConfig>>(() {
      return AiConfigListNotifier();
    });

class AiConfigListNotifier extends AsyncNotifier<List<AiConfig>> {
  @override
  Future<List<AiConfig>> build() async {
    void onWorkspaceChange(WorkspaceChangeEvent event) {
      if (event.path == '/settings/ai.json') {
        refresh();
      }
    }

    WorkspaceEventBus.instance.addListener(onWorkspaceChange);
    ref.onDispose(() {
      WorkspaceEventBus.instance.removeListener(onWorkspaceChange);
    });
    final repo = ConfigRepository.instance;
    return repo.getAllAiConfigs();
  }

  Future<void> refresh() async {
    final repo = ConfigRepository.instance;
    state = AsyncData(await repo.getAllAiConfigs());
  }

  Future<AiConfig> addConfig(AiConfig config) async {
    final repo = ConfigRepository.instance;
    await repo.insertAiConfig(config);
    // 内存增量更新，避免全表重查
    state = AsyncData([...(state.valueOrNull ?? []), config]);
    return config;
  }

  Future<void> updateConfig(AiConfig config) async {
    final repo = ConfigRepository.instance;
    await repo.updateAiConfig(config);
    // 内存替换目标项
    state = AsyncData(
      (state.valueOrNull ?? [])
          .map((c) => c.id == config.id ? config : c)
          .toList(),
    );
  }

  Future<void> deleteConfig(String id) async {
    final repo = ConfigRepository.instance;
    await repo.deleteAiConfig(id);
    // 内存移除
    state = AsyncData(
      (state.valueOrNull ?? []).where((c) => c.id != id).toList(),
    );
  }
}

final defaultAiConfigProvider = FutureProvider<AiConfig?>((ref) async {
  final repo = ConfigRepository.instance;
  return repo.getDefaultAiConfig();
});

Future<void> saveAiRoles(AiRoles roles) async {
  final repo = ConfigRepository.instance;
  await repo.saveAiRoles(roles);
}

Future<void> saveAiTemperatures(AiTemperatures temps) async {
  final repo = ConfigRepository.instance;
  await repo.saveAiTemperatures(temps);
}

final chatSessionListProvider =
    AsyncNotifierProvider<ChatSessionListNotifier, List<ChatSession>>(() {
      return ChatSessionListNotifier();
    });

class ChatSessionListNotifier extends AsyncNotifier<List<ChatSession>> {
  @override
  Future<List<ChatSession>> build() async {
    void onWorkspaceChange(WorkspaceChangeEvent event) {
      if (event.path.startsWith('/chats/')) {
        refresh();
      }
    }

    WorkspaceEventBus.instance.addListener(onWorkspaceChange);
    ref.onDispose(() {
      WorkspaceEventBus.instance.removeListener(onWorkspaceChange);
    });

    final repo = ConfigRepository.instance;
    return repo.getAllChatSessions();
  }

  Future<void> refresh() async {
    final repo = ConfigRepository.instance;
    state = AsyncData(await repo.getAllChatSessions());
  }

  Future<ChatSession> createSession({String? aiConfigId}) async {
    final repo = ConfigRepository.instance;
    final now = DateTime.now();
    final greeting = defaultSystemPrompts['assistant_greeting'] ?? '';
    final session = ChatSession(
      id: const Uuid().v4(),
      title: '新对话',
      aiConfigId: aiConfigId,
      messages: greeting.isNotEmpty
          ? [ChatMessage(role: 'assistant', content: greeting, timestamp: now)]
          : const [],
      createdAt: now,
      updatedAt: now,
    );
    await repo.insertChatSession(session);
    // 内存增量更新（最新在前，与 updated_at DESC 排序一致），避免全表重查
    state = AsyncData([session, ...(state.valueOrNull ?? [])]);
    return session;
  }

  /// 将 [session] 回写到内存列表（替换或插入并按 updatedAt 降序重排），不写库。
  ///
  /// 供 CurrentChatNotifier 等直接落库的场景同步历史抽屉，避免重复持久化
  void upsertLocal(ChatSession session) {
    final list = (state.valueOrNull ?? [])
        .map((s) => s.id == session.id ? session : s)
        .toList();
    if (!list.any((s) => s.id == session.id)) {
      list.add(session);
    }
    list.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    state = AsyncData(list);
  }

  Future<void> updateSession(ChatSession session) async {
    final repo = ConfigRepository.instance;
    await repo.updateChatSession(session);
    // 内存替换目标项并按 updatedAt 降序重排，保持与数据库查询排序一致
    final list = (state.valueOrNull ?? [])
        .map((s) => s.id == session.id ? session : s)
        .toList();
    list.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    state = AsyncData(list);
  }

  Future<void> deleteSession(String id) async {
    // 该会话若有进行中的小Q任务，先取消：避免任务结束时又把消息落回已删除会话
    ref.read(currentChatProvider.notifier).cancelSessionAgent(id);
    final repo = ConfigRepository.instance;
    await repo.softDeleteChatSession(id);
    // 内存移除
    state = AsyncData(
      (state.valueOrNull ?? []).where((s) => s.id != id).toList(),
    );
  }
}

final currentChatProvider =
    StateNotifierProvider<CurrentChatNotifier, ChatSession?>((ref) {
      return CurrentChatNotifier(ref);
    });

final aiStreamingMessageProvider = StateProvider<String?>((ref) => null);

/// 小Q 流式过程中的阶段性状态文案（思考中/准备中/执行工具等），
/// 与 [aiStreamingMessageProvider] 互斥展示：写状态时清空正文，写正文时清空状态
final aiStreamingStatusProvider = StateProvider<String?>((ref) => null);

/// 本轮 Agent 任务的开始时间（agentStart 时记录，结束清理），
/// 供状态行显示「已用时」计时，传达任务仍在进行
final aiStreamingStartedAtProvider = StateProvider<DateTime?>((ref) => null);

/// 「思考中」期间模型实时下发的思考过程文本（reasoning_content 流式增量），
/// 展示在状态卡内的限高滚动区减少等待体感；模型不返回思考内容时保持 null，
/// 界面与现状完全一致
final aiStreamingThoughtProvider = StateProvider<String?>((ref) => null);

/// 正在运行小Q任务的会话 ID 集合：历史抽屉据此为对应会话显示「生成中」动画，
/// 输入区据此判断当前会话能否发送/是否显示停止按钮
final agentRunningSessionsProvider = StateProvider<Set<String>>((ref) => {});

/// 一个进行中小Q任务的全部运行态。
///
/// 流式缓冲与消息累积都挂在任务自身、以发起会话为归属，与「当前打开的会话」解耦：
/// 任务执行期间用户新建/切换对话后，事件继续累积到本对象并在结束时落回发起会话，
/// 新会话不被串写（对齐悬浮小Q的签名隔离思路）
class _ActiveAgentRun {
  _ActiveAgentRun(this.sessionId, this.token, this.title);

  /// 发起任务时捕获的会话 ID，任务生命周期内不变
  final String sessionId;
  final AgentCancellationToken token;

  /// 发起时确定的会话标题（首条消息时取消息摘要），落库回写用
  String title;

  /// 流式正文缓冲（与思考缓冲共用同一个节流 flush 定时器）
  final StringBuffer contentBuffer = StringBuffer();

  /// 「思考中」期间的模型思考增量缓冲
  final StringBuffer thoughtBuffer = StringBuffer();

  /// 流式文本刷新节流定时器
  Timer? flushTimer;

  /// 最近一次阶段性状态文案（切回会话时恢复显示用）
  String? statusText;

  /// 任务开始时间（agentStart 时记录）
  DateTime? startedAt;

  /// 本轮消息累积：以发起时的会话消息与用户消息开头，随事件追加，
  /// 会话未被切走时同步到界面，任务结束后整体落回发起会话
  final List<ChatMessage> messages = [];
}

class CurrentChatNotifier extends StateNotifier<ChatSession?> {
  final Ref _ref;

  CurrentChatNotifier(this._ref) : super(null);

  /// 进行中的小Q任务（key = 发起会话 ID）；不同会话可各自运行一个任务
  final Map<String, _ActiveAgentRun> _activeRuns = {};

  bool _isRollingBack = false;

  /// 当前打开的会话是否有进行中的小Q任务
  /// （据此禁用撤回/继续/暂停等重入操作，会话级语义）
  bool get isStreaming {
    final id = state?.id;
    return id != null && _activeRuns.containsKey(id);
  }

  /// 是否正在执行撤回（防重入，UI 据此禁用输入与重复触发）
  bool get isRollingBack => _isRollingBack;

  /// 主动取消/中止当前会话的 Agent 执行（对齐 Pi Agent 的 abort 控制）
  void cancelCurrentAgent([String? reason]) {
    final id = state?.id;
    if (id != null) {
      cancelSessionAgent(id, reason);
    }
  }

  /// 取消指定会话正在运行的小Q任务（删除会话时调用，避免任务结束后落回已删会话）
  void cancelSessionAgent(String sessionId, [String? reason]) {
    _activeRuns[sessionId]?.token.cancel(reason);
  }

  /// 把进行中任务的会话 ID 集合同步到全局 Provider
  /// （历史抽屉「生成中」动画与输入区停止按钮的判断依据）
  void _publishRunningSessions() {
    _ref
        .read(agentRunningSessionsProvider.notifier)
        .state = _activeRuns.keys.toSet();
  }

  /// 将最近一条步数上限消息标记为已处理（隐藏「继续/暂停」按钮）并持久化
  Future<void> _markTurnLimitHandled() async {
    if (state == null) return;
    final messages = List<ChatMessage>.from(state!.messages);
    int? index;
    for (var i = messages.length - 1; i >= 0; i--) {
      if (messages[i].uiDetails?['type'] == 'turn_limit') {
        index = i;
        break;
      }
    }
    if (index == null) return;
    messages[index] = messages[index].copyWith(
      uiDetails: {...?messages[index].uiDetails, 'handled': true},
    );
    state = state!.copyWith(messages: messages);
    await ConfigRepository.instance.updateChatSession(state!);
    _syncSessionToList();
  }

  /// 把当前会话回写到会话列表的内存态（不重复写库），
  /// 让历史抽屉即时看到最新标题与时间（否则要等重启或 /chats/ 事件才刷新）
  void _syncSessionToList() {
    final session = state;
    if (session == null) return;
    _ref.read(chatSessionListProvider.notifier).upsertLocal(session);
  }

  /// 步数上限消息是否待处理（UI 据此渲染/启用「继续/暂停」按钮）
  bool get hasPendingTurnLimit {
    return state?.messages.any(
          (m) =>
              m.uiDetails?['type'] == 'turn_limit' &&
              m.uiDetails?['handled'] != true,
        ) ??
        false;
  }

  /// 点击「继续」：标记按钮已处理后以「继续」指令重启 Agent 循环接着执行
  Future<void> continueAfterTurnLimit() async {
    if (isStreaming) return;
    await _markTurnLimitHandled();
    await sendMessage('继续');
  }

  /// 点击「暂停」：仅隐藏按钮，已完成的工作保留，任务就此结束
  Future<void> pauseAfterTurnLimit() async {
    if (isStreaming) return;
    await _markTurnLimitHandled();
  }

  /// 任务会话是否仍是当前打开的会话（全局流式 UI 写入的总守卫）
  bool _bindsCurrentSession(_ActiveAgentRun run) {
    return state?.id == run.sessionId;
  }

  /// 以约 60ms 的节奏批量刷新流式文本到 UI（人眼流畅且不逐 token 重建），
  /// 正文与思考缓冲共用本定时器；正文已开始时思考区随状态行一并退场。
  /// 仅当任务会话仍是当前打开的会话时才写全局流式 Provider——
  /// 用户切走后任务继续在后台累积缓冲，气泡不串显到别的会话
  void _scheduleRunFlush(_ActiveAgentRun run) {
    if (run.flushTimer != null && run.flushTimer!.isActive) return;
    run.flushTimer = Timer(const Duration(milliseconds: 60), () {
      if (!_bindsCurrentSession(run)) return;
      final content = run.contentBuffer.toString();
      if (content.isNotEmpty) {
        _ref.read(aiStreamingMessageProvider.notifier).state = content;
        _ref.read(aiStreamingStatusProvider.notifier).state = null;
        _ref.read(aiStreamingThoughtProvider.notifier).state = null;
      } else if (run.thoughtBuffer.isNotEmpty) {
        _ref.read(aiStreamingThoughtProvider.notifier).state =
            run.thoughtBuffer.toString();
      }
    });
  }

  /// 写入阶段性状态文案并清空流式正文（占位气泡切到状态行展示），
  /// 同时取消待触发的正文 flush，避免旧缓冲在状态展示后被迟到刷出；
  /// 仅当任务会话仍是当前打开的会话时才写全局流式 Provider
  void _setRunStatus(_ActiveAgentRun run, String text) {
    run.flushTimer?.cancel();
    run.flushTimer = null;
    run.statusText = text;
    if (!_bindsCurrentSession(run)) return;
    _ref.read(aiStreamingMessageProvider.notifier).state = null;
    _ref.read(aiStreamingStatusProvider.notifier).state = text;
  }

  /// 清空全局流式 UI 四件套（正文/状态/思考/开始时间）
  void _clearStreamingProviders() {
    _ref.read(aiStreamingMessageProvider.notifier).state = null;
    _ref.read(aiStreamingStatusProvider.notifier).state = null;
    _ref.read(aiStreamingThoughtProvider.notifier).state = null;
    _ref.read(aiStreamingStartedAtProvider.notifier).state = null;
  }

  /// 切回正在工作的会话时，从任务运行态恢复流式 UI 快照
  /// （正文/状态行/思考区/开始计时，与 flush 写入的展示语义一致）
  void _restoreRunUi(_ActiveAgentRun run) {
    final content = run.contentBuffer.toString();
    if (content.isNotEmpty) {
      _ref.read(aiStreamingMessageProvider.notifier).state = content;
      _ref.read(aiStreamingStatusProvider.notifier).state = null;
      _ref.read(aiStreamingThoughtProvider.notifier).state = null;
    } else {
      _ref.read(aiStreamingStatusProvider.notifier).state =
          run.statusText ?? '小Q思考中';
      _ref.read(aiStreamingThoughtProvider.notifier).state =
          run.thoughtBuffer.isNotEmpty ? run.thoughtBuffer.toString() : null;
    }
    _ref.read(aiStreamingStartedAtProvider.notifier).state = run.startedAt;
  }

  void setSession(ChatSession? session) {
    // 流式气泡/状态行/思考区随会话走：先卸下，避免上一会话的流式内容串显到目标会话
    _clearStreamingProviders();

    // 目标会话若有进行中的小Q任务：以任务内的消息累积为准恢复
    // （列表/库里的会话对象是过期快照，缺少任务中途产生的中间消息）
    final run = session == null ? null : _activeRuns[session.id];
    if (run != null && run.messages.isNotEmpty) {
      session = session!.copyWith(messages: List.of(run.messages));
    }

    state = session;
    if (run != null) {
      _restoreRunUi(run);
    }

    // 持久化最后活跃会话 ID，供下次启动恢复
    SharedPreferences.getInstance().then((prefs) {
      if (session != null) {
        prefs.setString('last_chat_session_id', session.id);
      } else {
        prefs.remove('last_chat_session_id');
      }
    });
  }

  /// 启动时从持久化存储恢复上次的会话
  Future<void> initLastSession() async {
    if (state != null) return;
    final prefs = await SharedPreferences.getInstance();
    final lastId = prefs.getString('last_chat_session_id');
    if (lastId == null) return;
    final session = await ConfigRepository.instance.getChatSession(lastId);
    if (session != null && !session.isDeleted) {
      state = session;
    }
  }

  /// 构建本次消息手动分享附件（日记/笔记/待办）的上下文数据块。
  ///
  /// Agent 模式下不再自动预注入时间线流水与长文日记（由小Q通过 VFS 工具自主探索），
  /// 仅注入用户显式分享的附件；无有效附件时返回空串。
  Future<String> buildAttachmentsContext({
    List<String>? attachNoteIds,
    List<String>? attachTodoIds,
    List<String>? attachJournalIds,
  }) async {
    // 1. 手动分享的日记（长文 Note）
    final allJournalNotes = <Note>[];
    if (attachJournalIds != null && attachJournalIds.isNotEmpty) {
      final noteRepo = NoteRepository();
      for (final jId in attachJournalIds) {
        if (!allJournalNotes.any((n) => n.id == jId)) {
          final jNote = await noteRepo.getById(jId);
          if (jNote != null && !jNote.isDeleted && jNote.content.trim().isNotEmpty) {
            allJournalNotes.add(jNote);
          }
        }
      }
    }
    allJournalNotes.sort((a, b) => b.title.compareTo(a.title));

    // 2. 手动分享的普通笔记（排除日记，避免重复展示）
    final filteredNotes = <Note>[];
    if (attachNoteIds != null && attachNoteIds.isNotEmpty) {
      final noteRepo = NoteRepository();
      for (final id in attachNoteIds) {
        if (JournalService.isJournalNote(id)) continue;
        final note = await noteRepo.getById(id);
        if (note != null && !note.isDeleted) {
          filteredNotes.add(note);
        }
      }
    }

    // 3. 手动分享的待办
    final filteredTodos = <Todo>[];
    if (attachTodoIds != null && attachTodoIds.isNotEmpty) {
      final todoRepo = TodoRepository();
      for (final id in attachTodoIds) {
        final todo = await todoRepo.getById(id);
        if (todo != null && !todo.isDeleted) {
          filteredTodos.add(todo);
        }
      }
    }

    if (allJournalNotes.isEmpty &&
        filteredNotes.isEmpty &&
        filteredTodos.isEmpty) {
      return '';
    }

    final buffer = StringBuffer();
    buffer.writeln('请基于以下数据回答我的问题：\n');

    // 拼接每日长篇日记
    if (allJournalNotes.isNotEmpty) {
      buffer.writeln('### 每日长篇日记\n');
      for (int i = 0; i < allJournalNotes.length; i++) {
        final j = allJournalNotes[i];
        buffer.writeln('#### 日记 ${i + 1} (${j.title})');
        if (j.tags.isNotEmpty) {
          buffer.writeln('- **标签**: ${j.tags}');
        }
        buffer.writeln('- **内容**:\n${j.content.trim()}\n');
      }
    }

    if (filteredNotes.isNotEmpty) {
      buffer.writeln('### 相关笔记\n');
      for (int i = 0; i < filteredNotes.length; i++) {
        final n = filteredNotes[i];
        buffer.writeln('#### 条目 ${i + 1}');
        buffer.writeln('- **标题**: ${n.title}');
        if (n.tags.isNotEmpty) {
          buffer.writeln('- **标签**: ${n.tags}');
        }
        if (n.content.isNotEmpty) {
          buffer.writeln('- **内容**: ${n.content}');
        }
        buffer.writeln();
      }
    }

    if (filteredTodos.isNotEmpty) {
      buffer.writeln('### 相关待办\n');
      for (int i = 0; i < filteredTodos.length; i++) {
        final t = filteredTodos[i];
        buffer.writeln('#### 待办 ${i + 1}');
        buffer.writeln('- **内容**: ${t.title}');
        if (t.description.isNotEmpty) buffer.writeln('- **描述**: ${t.description}');
        buffer.writeln('- **状态**: ${t.isCompleted ? '已完成' : '未完成'}');
        buffer.writeln('- **优先级**: ${t.priority == 'high' ? '高' : (t.priority == 'important' ? '重要' : '普通')}');
        if (t.dueDate != null) buffer.writeln('- **到期日**: ${_formatDateTime(t.dueDate!)}');
        if (t.tags.isNotEmpty) buffer.writeln('- **标签**: ${t.tags}');
        buffer.writeln();
      }
    }

    return buffer.toString().trim();
  }

  String _formatDateTime(DateTime dt) {
    return DateFormat('yyyy-MM-dd HH:mm').format(dt);
  }

  Future<void> sendMessage(
    String content, {
    List<String>? images,
    List<String>? noteIds,
    List<String>? todoIds,
    List<String>? journalIds,
    String? skillName,
  }) async {
    if (state == null) return;

    final now = DateTime.now();
    final repo = ConfigRepository.instance;

    // 1. Append user message with raw content and optional images to active display/save history immediately
    final hasRefAttachments = (noteIds?.isNotEmpty ?? false) ||
        (todoIds?.isNotEmpty ?? false) ||
        (journalIds?.isNotEmpty ?? false);
    final userMessage = ChatMessage(
      role: 'user',
      content: content,
      timestamp: now,
      images: images,
      // 笔记/待办/日记引用存入 uiDetails，失败重试时据此完整还原提问；
      // 构建模型请求时不会序列化该字段，不会泄漏进上下文
      uiDetails: hasRefAttachments
          ? {
              'attachments': {
                if (noteIds?.isNotEmpty ?? false) 'notes': noteIds,
                if (todoIds?.isNotEmpty ?? false) 'todos': todoIds,
                if (journalIds?.isNotEmpty ?? false) 'journals': journalIds,
              },
            }
          : null,
    );
    final updatedMessages = [...state!.messages, userMessage];

    // Determine the updated session title if it is default
    String newTitle = state!.title;
    if (state!.title == '新对话' ||
        state!.messages.isEmpty ||
        (state!.messages.length == 1 &&
            state!.messages.first.role == 'assistant')) {
      newTitle = content.substring(
        0,
        content.length > 20 ? 20 : content.length,
      );
    }

    // 任务绑定发起会话：流式过程中用户可能新建/切换对话，
    // 消息累积与最终落库始终以发起会话为准，不写当前打开的其他会话。
    // 取消令牌随任务注册一并创建：保证「准备中」阶段（附件上下文构建）也能响应停止
    final startSessionId = state!.id;
    final run = _ActiveAgentRun(
      startSessionId,
      AgentCancellationToken(),
      newTitle,
    )..messages.addAll(updatedMessages);
    _activeRuns[startSessionId] = run;
    _publishRunningSessions();

    state = state!.copyWith(title: newTitle, messages: updatedMessages);

    // 开始录制本轮 VFS 变更（撤回/再次编辑功能的数据来源）；句柄制支持与悬浮小Q任务并发录制
    final recorderHandle = VirtualWorkspaceService.instance.startRecording();

    try {
      // 2. 仅注入用户手动分享的附件上下文，其余数据由小Q通过VFS工具自主探索
      final attachmentContext = await buildAttachmentsContext(
        attachNoteIds: noteIds,
        attachTodoIds: todoIds,
        attachJournalIds: journalIds,
      );
      final String? dataContext =
          attachmentContext.isEmpty ? null : attachmentContext;

      // 准备阶段（资料/关联数据导出）可能较久：若用户已点停止，补一条中止提示后直接收尾
      if (run.token.isCancelled) {
        run.messages.add(ChatMessage(
          role: 'assistant',
          content: '(操作已被用户主动中止)',
          timestamp: DateTime.now(),
        ));
        if (_bindsCurrentSession(run)) {
          state = state!.copyWith(messages: List.of(run.messages));
        }
        return;
      }

      // 预加载用户技能缓存：斜杠命令解析与系统提示词技能索引都依赖它
      await SkillRegistry.instance.ensureLoaded();

      // 斜杠命令显式激活的技能：手册直接注入上下文（省一次 read_file 往返），
      // 并记一次使用统计；技能不存在时静默按普通消息处理
      String? skillDoc;
      if (skillName != null && skillName.isNotEmpty) {
        skillDoc = SkillRegistry.instance.getSkillContent(skillName);
        if (skillDoc != null) {
          unawaited(SkillUsageTracker.instance.record(skillName));
        }
      }

      // 3. 构建动态环境上下文（时间/用户资料/关联数据），注入 system 尾部而非污染用户消息原文
      final dynamicContext = await buildBaseDynamicContext(
        extraSections: [
          if (dataContext != null && dataContext.isNotEmpty)
            '关联数据（用户引用的待办/笔记/日记等）:\n$dataContext',
          if (skillDoc != null)
            '激活技能手册（用户以 /$skillName 命令显式调用，请严格遵循该手册的规范执行本次任务）:\n$skillDoc',
        ],
      );

      final aiService = _ref.read(aiServiceProvider);
      final roleSettings = await AiRoleService.instance.getSettingsForRole(
        'assistant',
      );

      _setRunStatus(run, '小Q思考中');

      // 初始化工具分发器并构建 AgentLoop（声明式注入 afterToolCall 钩子）；
      // 可选工具按用户配置裁剪：禁用的工具不注册，系统提示词对应准则段也不注入
      final disabledTools = await AgentToolConfig.instance.getDisabledTools();
      final dispatcher = AgentToolRegistry.createDefaultDispatcher(
        disabledTools: disabledTools,
      );
      
      // 预先配置好 AiService：统一使用角色绑定的生效模型配置
      final assistantConfig = await AiRoleService.instance
          .getEffectiveConfigForRole('assistant');
      aiService.updateConfig(
        assistantConfig,
        temperature: roleSettings.temperature,
        maxTokens: roleSettings.maxTokens,
      );

      // 读取当前激活个性（对话开始时取一次，本轮中途的修改下轮生效——对齐记忆的冻结快照语义）
      final personality = await QPersonalityService.instance.getActivePersonality();

      final agentLoop = AgentLoop(
        aiService: aiService,
        dispatcher: dispatcher,
        maxTurns: 20,
        afterToolCall: (call, result) async {
          // 按 VFS 路径前缀联动刷新对应业务数据
          refreshWorkspaceSideEffects(
            _ref,
            call.arguments['path'] as String? ?? '',
          );
        },
      );

      // 历史保持用户原文（时间/资料等环境信息已注入 system 尾部，每轮可见且不污染历史）
      final List<ChatMessage> conversationHistory = List.from(updatedMessages);

      ChatMessage? finalResponse;

      await for (final event in agentLoop.run(
        conversationHistory: conversationHistory,
        systemPrompt: QSystemPrompt.buildSystemPrompt(
          personalityPrompt: personality.prompt,
          enabledOptionalTools:
              AgentToolRegistry.optionalToolNames.difference(disabledTools),
        ),
        dynamicContext: dynamicContext,
        cancellationToken: run.token,
      )) {
        switch (event.type) {
          case AgentEventType.agentStart:
            run.thoughtBuffer.clear();
            run.startedAt = DateTime.now();
            if (_bindsCurrentSession(run)) {
              _ref.read(aiStreamingThoughtProvider.notifier).state = null;
              _ref.read(aiStreamingStartedAtProvider.notifier).state =
                  run.startedAt;
            }
            _setRunStatus(run, '小Q准备中');
            break;
          case AgentEventType.turnStart:
            run.contentBuffer.clear();
            // 新一轮思考从零开始，与状态行「第 N 步」语义对齐
            run.thoughtBuffer.clear();
            if (_bindsCurrentSession(run)) {
              _ref.read(aiStreamingThoughtProvider.notifier).state = null;
            }
            // 首轮不展示步数，避免“第 1 步”这类无信息量文案
            _setRunStatus(run, (event.turn ?? 0) > 1
                ? '小Q思考中 · 第 ${event.turn} 步'
                : '小Q思考中');
            break;
          case AgentEventType.contentDelta:
            if (event.text != null) {
              run.contentBuffer.write(event.text);
              _scheduleRunFlush(run);
            }
            break;
          case AgentEventType.reasoningDelta:
            if (event.text != null) {
              run.thoughtBuffer.write(event.text);
              _scheduleRunFlush(run);
            }
            break;
          case AgentEventType.thoughtUpdate:
            // 轮末完整思考文本直接落入思考区展示（含 <thought> 标签协议路径），
            // 不再作为瞬态状态行文案被下一事件覆盖
            final thoughtText = event.text;
            if (thoughtText != null && thoughtText.isNotEmpty) {
              run.thoughtBuffer
                ..clear()
                ..write(thoughtText);
              if (_bindsCurrentSession(run)) {
                _ref.read(aiStreamingThoughtProvider.notifier).state =
                    thoughtText;
              }
            }
            break;
          case AgentEventType.toolCalling:
            // 模型正在流式生成工具调用参数（大参数期间可达数十秒），
            // 提前展示目标文件等信息，避免状态行停留在「思考中」形似卡死
            final callingTool = event.toolCall;
            if (callingTool != null && callingTool.name.isNotEmpty) {
              _setRunStatus(
                run,
                '⚡ ${AgentToolLabels.progressLabel(callingTool.name, callingTool.arguments)}',
              );
            }
            break;
          case AgentEventType.toolExecuting:
            final toolName = event.toolCall?.name ?? '';
            final extraProgress = event.text != null ? '（${event.text}）' : '';
            // 尾部不再拼字面省略号，由 UI 的动态省略号动画表达进行中
            _setRunStatus(
              run,
              '⚡ ${AgentToolLabels.progressLabel(toolName, event.toolCall?.arguments)}$extraProgress',
            );
            break;
          case AgentEventType.toolCompleted:
            // 每当工具执行完成后推入中间消息：始终累积到任务自身，
            // 仅当会话未被切走时才同步到界面，避免覆写用户新打开的会话
            if (event.message != null) {
              run.messages.add(event.message!);
              if (_bindsCurrentSession(run)) {
                state = state!.copyWith(messages: List.of(run.messages));
              }
            }
            break;
          case AgentEventType.turnEnd:
            // 单轮结束，准备下一轮
            break;
          case AgentEventType.assistantMessage:
            if (event.message != null) {
              run.messages.add(event.message!);
              if (_bindsCurrentSession(run)) {
                state = state!.copyWith(messages: List.of(run.messages));
              }
            }
            break;
          case AgentEventType.finished:
            finalResponse = event.message;
            break;
          case AgentEventType.agentEnd:
            // 整个 Agent 任务终结
            break;
          case AgentEventType.error:
            throw Exception(event.error ?? 'Agent 执行异常');
        }
      }

      if (finalResponse != null) {
        // 避免重复追加相同内容的最终答复
        final bool isAlreadyAdded = run.messages.isNotEmpty &&
            (run.messages.last == finalResponse ||
                (run.messages.last.role == 'assistant' &&
                    run.messages.last.content.trim() == finalResponse.content.trim()));

        if (!isAlreadyAdded) {
          run.messages.add(finalResponse);
        }
        if (_bindsCurrentSession(run)) {
          state = state!.copyWith(messages: List.of(run.messages));
        }
      }
    } catch (e, stackTrace) {
      LoggerService.instance.logAI(
        'AI对话发送失败: $e',
        level: LogLevel.error,
        details: stackTrace.toString(),
      );
      final errorMessage = ChatMessage(
        role: 'assistant',
        content: '抱歉，本轮对话请求失败了。\n\n'
            '${AiErrorExplainer.describe(e)}\n\n'
            '长按本条消息可重试本轮对话。',
        timestamp: DateTime.now(),
        isError: true,
      );
      // 错误消息替换中间消息的语义两条路径保持一致：会话未切走时同步到界面，
      // 已切走时只改任务累积，最终随落库写回发起会话
      run.messages
        ..clear()
        ..addAll([...updatedMessages, errorMessage]);
      if (_bindsCurrentSession(run)) {
        state = state!.copyWith(messages: [...updatedMessages, errorMessage]);
      }
    } finally {
      _activeRuns.remove(startSessionId);
      _publishRunningSessions();
      run.flushTimer?.cancel();
      run.flushTimer = null;

      // 流式 UI 只在用户仍停留在本任务会话时才清——
      // 已切走时界面属于目标会话（setSession 已卸载或被其他任务接管），不可误清
      if (_bindsCurrentSession(run)) {
        _clearStreamingProviders();
      }

      // 结束录制，把本轮 VFS 变更快照挂到本轮用户消息上（随会话落库，撤回时按此恢复）
      final undoEntries = VirtualWorkspaceService.instance.stopRecording(recorderHandle);
      if (undoEntries.isNotEmpty && run.messages.isNotEmpty) {
        final userIndex = updatedMessages.length - 1;
        final messages = List<ChatMessage>.from(run.messages);
        if (userIndex >= 0 &&
            userIndex < messages.length &&
            messages[userIndex].role == 'user') {
          messages[userIndex] = messages[userIndex].copyWith(
            undoLog: WorkspaceUndoEntry.encodeList(undoEntries),
          );
          run.messages
            ..clear()
            ..addAll(messages);
          if (_bindsCurrentSession(run)) {
            state = state!.copyWith(messages: messages);
          }
        }
      }

      // 最终落库：会话未切走直接用 state（含标题等最新界面态）；已切走则把任务
      // 累积写回发起会话（发起会话已被删除时跳过，避免把消息复活进已删数据）
      ChatSession? finalSession;
      if (_bindsCurrentSession(run)) {
        finalSession = state;
      } else {
        final base = await repo.getChatSession(startSessionId);
        if (base != null && !base.isDeleted) {
          finalSession = base.copyWith(
            title: run.title,
            messages: List.of(run.messages),
          );
        }
      }
      if (finalSession != null) {
        await repo.updateChatSession(finalSession);
        _ref.read(chatSessionListProvider.notifier).upsertLocal(finalSession);
      }
    }
  }

  /// 撤回：回退到 [userMessageIndex] 这条用户消息发起前。
  ///
  /// 先逆序恢复该轮及其后所有轮次记录的 VFS 变更快照（数据回退），再截断该轮起的
  /// 全部消息并落库（上下文回退）——由于 LLM 上下文每次发送都从会话消息现场构建，
  /// 截断后对话上下文同步精确回到撤回节点。
  ///
  /// 返回 `(恢复成功处数, 恢复失败处数)`；返回 null 表示当前状态不可撤回
  /// （生成中/正在撤回/越界/非用户消息）。
  Future<(int restored, int failed)?> rollbackToMessage(int userMessageIndex) async {
    if (state == null) return null;
    if (isStreaming) return null;
    if (_isRollingBack) return null;
    final messages = state!.messages;
    if (userMessageIndex < 0 || userMessageIndex >= messages.length) return null;
    if (messages[userMessageIndex].role != 'user') return null;

    _isRollingBack = true;
    int restored = 0;
    int failed = 0;
    try {
      // 收集该轮（含）之后所有用户消息的变更快照，逆序恢复（后一轮的修改先撤销）
      final entries = messages
          .skip(userMessageIndex)
          .where((m) => m.role == 'user')
          .expand((m) => WorkspaceUndoEntry.decodeList(m.undoLog))
          .toList();
      (restored, failed) = await restoreWorkspaceUndoEntries(_ref, entries);

      // 截断该轮起的所有消息（含 assistant/tool 中间消息与后续轮次）并落库
      state = state!.copyWith(messages: messages.sublist(0, userMessageIndex));
      await ConfigRepository.instance.updateChatSession(state!);
      _syncSessionToList();

      // 恢复写入不走 AgentLoop 的 afterToolCall 钩子，手动补齐业务数据联动刷新
      refreshAllBusinessData(_ref);
    } finally {
      _isRollingBack = false;
    }

    return (restored, failed);
  }
}
