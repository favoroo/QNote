import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:qnote_flutter/config/defaults.dart';
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

class CurrentChatNotifier extends StateNotifier<ChatSession?> {
  final Ref _ref;

  CurrentChatNotifier(this._ref) : super(null);

  final StringBuffer _streamingContent = StringBuffer();
  bool _isStreaming = false;
  bool _isRollingBack = false;
  AgentCancellationToken? _currentCancellationToken;

  /// 流式文本刷新节流定时器：批量合并 delta，避免每 token 触发 UI 重建
  Timer? _streamingFlushTimer;

  bool get isStreaming => _isStreaming;

  /// 是否正在执行撤回（防重入，UI 据此禁用输入与重复触发）
  bool get isRollingBack => _isRollingBack;

  /// 主动取消/中止当前 Agent 执行（对齐 Pi Agent 的 abort 控制）
  void cancelCurrentAgent([String? reason]) {
    _currentCancellationToken?.cancel(reason);
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
    if (_isStreaming) return;
    await _markTurnLimitHandled();
    await sendMessage('继续');
  }

  /// 点击「暂停」：仅隐藏按钮，已完成的工作保留，任务就此结束
  Future<void> pauseAfterTurnLimit() async {
    if (_isStreaming) return;
    await _markTurnLimitHandled();
  }

  /// 以约 60ms 的节奏批量刷新流式文本到 UI（人眼流畅且不逐 token 重建）
  void _scheduleStreamingFlush() {
    if (_streamingFlushTimer != null && _streamingFlushTimer!.isActive) return;
    _streamingFlushTimer = Timer(const Duration(milliseconds: 60), () {
      _ref.read(aiStreamingMessageProvider.notifier).state =
          _streamingContent.toString();
      _ref.read(aiStreamingStatusProvider.notifier).state = null;
    });
  }

  /// 写入阶段性状态文案并清空流式正文（占位气泡切到状态行展示），
  /// 同时取消待触发的正文 flush，避免旧缓冲在状态展示后被迟到刷出
  void _setStreamingStatus(String text) {
    _streamingFlushTimer?.cancel();
    _streamingFlushTimer = null;
    _ref.read(aiStreamingMessageProvider.notifier).state = null;
    _ref.read(aiStreamingStatusProvider.notifier).state = text;
  }

  void setSession(ChatSession? session) {
    state = session;
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
  }) async {
    if (state == null) return;

    final now = DateTime.now();
    final repo = ConfigRepository.instance;

    // 1. Append user message with raw content and optional images to active display/save history immediately
    final userMessage = ChatMessage(
      role: 'user',
      content: content,
      timestamp: now,
      images: images,
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

    state = state!.copyWith(title: newTitle, messages: updatedMessages);

    _isStreaming = true;
    _streamingContent.clear();
    // 开始录制本轮 VFS 变更（撤回/再次编辑功能的数据来源）；句柄制支持与悬浮小Q任务并发录制
    final recorderHandle = VirtualWorkspaceService.instance.startRecording();

    // 取消令牌必须在最前创建：否则"准备中"阶段（附件上下文构建）点停止时为 null，取消静默失效
    final token = AgentCancellationToken();
    _currentCancellationToken = token;

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
      if (token.isCancelled) {
        state = state!.copyWith(messages: [
          ...updatedMessages,
          ChatMessage(
            role: 'assistant',
            content: '(操作已被用户主动中止)',
            timestamp: DateTime.now(),
          ),
        ]);
        return;
      }

      // 3. 构建动态环境上下文（时间/用户资料/关联数据），注入 system 尾部而非污染用户消息原文
      final dynamicContext = await buildBaseDynamicContext(
        extraSections: [
          if (dataContext != null && dataContext.isNotEmpty)
            '关联数据（用户引用的待办/笔记/日记等）:\n$dataContext',
        ],
      );

      final aiService = _ref.read(aiServiceProvider);
      final roleSettings = await AiRoleService.instance.getSettingsForRole(
        'assistant',
      );

      _setStreamingStatus('小Q思考中');

      // 初始化工具分发器并构建 AgentLoop（声明式注入 afterToolCall 钩子）
      final dispatcher = AgentToolRegistry.createDefaultDispatcher();
      
      // 预先配置好 AiService：统一使用角色绑定的生效模型配置
      final assistantConfig = await AiRoleService.instance
          .getEffectiveConfigForRole('assistant');
      aiService.updateConfig(
        assistantConfig,
        temperature: roleSettings.temperature,
        maxTokens: roleSettings.maxTokens,
      );

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
      final sessionMessages = [...updatedMessages];

      await for (final event in agentLoop.run(
        conversationHistory: conversationHistory,
        systemPrompt: QSystemPrompt.prompt,
        dynamicContext: dynamicContext,
        cancellationToken: token,
      )) {
        switch (event.type) {
          case AgentEventType.agentStart:
            _setStreamingStatus('小Q准备中');
            break;
          case AgentEventType.turnStart:
            _streamingContent.clear();
            // 首轮不展示步数，避免“第 1 步”这类无信息量文案
            _setStreamingStatus((event.turn ?? 0) > 1
                ? '小Q思考中 · 第 ${event.turn} 步'
                : '小Q思考中');
            break;
          case AgentEventType.contentDelta:
            if (event.text != null) {
              _streamingContent.write(event.text!);
              _scheduleStreamingFlush();
            }
            break;
          case AgentEventType.thoughtUpdate:
            if (event.text != null && event.text!.isNotEmpty) {
              _setStreamingStatus('💭 思考过程:\n${event.text}');
            }
            break;
          case AgentEventType.toolExecuting:
            final toolName = event.toolCall?.name ?? '';
            final extraProgress = event.text != null ? '（${event.text}）' : '';
            // 尾部不再拼字面省略号，由 UI 的动态省略号动画表达进行中
            _setStreamingStatus(
              '⚡ ${AgentToolLabels.progressLabel(toolName, event.toolCall?.arguments)}$extraProgress',
            );
            break;
          case AgentEventType.toolCompleted:
            // 每当工具执行完成后，推入中间消息
            if (event.message != null) {
              sessionMessages.add(event.message!);
              state = state!.copyWith(messages: List.from(sessionMessages));
            }
            break;
          case AgentEventType.turnEnd:
            // 单轮结束，准备下一轮
            break;
          case AgentEventType.assistantMessage:
            if (event.message != null) {
              sessionMessages.add(event.message!);
              state = state!.copyWith(messages: List.from(sessionMessages));
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
        final bool isAlreadyAdded = sessionMessages.isNotEmpty &&
            (sessionMessages.last == finalResponse ||
                (sessionMessages.last.role == 'assistant' &&
                    sessionMessages.last.content.trim() == finalResponse.content.trim()));

        if (!isAlreadyAdded) {
          sessionMessages.add(finalResponse);
        }
        state = state!.copyWith(messages: sessionMessages);
      }
    } catch (e, stackTrace) {
      LoggerService.instance.logAI(
        'AI对话发送失败: $e',
        level: LogLevel.error,
        details: stackTrace.toString(),
      );
      final errorMessage = ChatMessage(
        role: 'assistant',
        content: '抱歉，发生了错误，请稍后重试。\n\n错误详情: $e',
        timestamp: DateTime.now(),
      );
      state = state!.copyWith(messages: [...updatedMessages, errorMessage]);
    } finally {
      _isStreaming = false;
      _currentCancellationToken = null;
      _streamingFlushTimer?.cancel();
      _streamingFlushTimer = null;
      _ref.read(aiStreamingMessageProvider.notifier).state = null;
      _ref.read(aiStreamingStatusProvider.notifier).state = null;

      // 结束录制，把本轮 VFS 变更快照挂到本轮用户消息上（随会话落库，撤回时按此恢复）
      final undoEntries = VirtualWorkspaceService.instance.stopRecording(recorderHandle);
      if (undoEntries.isNotEmpty && state != null) {
        final userIndex = updatedMessages.length - 1;
        final messages = List<ChatMessage>.from(state!.messages);
        if (userIndex >= 0 &&
            userIndex < messages.length &&
            messages[userIndex].role == 'user') {
          messages[userIndex] = messages[userIndex].copyWith(
            undoLog: WorkspaceUndoEntry.encodeList(undoEntries),
          );
          state = state!.copyWith(messages: messages);
        }
      }

      if (state != null) {
        await repo.updateChatSession(state!);
        _syncSessionToList();
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
    if (_isStreaming) return null;
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
